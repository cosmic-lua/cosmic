#include "coverage.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lapi.h"
#include "lstate.h"

/* Lua is pinned with the core. Reading the current Lua closure's source
 * directly avoids lua_getinfo("S") formatting a display name on every line.
 * Never cache CallInfo: Lua reuses frames. Each cached TString is kept alive
 * in the collector's uservalue table, including long strings. */
#define SOURCE_BUCKETS 256
#define PAGE_BITS 4096

typedef struct HitPage {
  struct HitPage *next;
  unsigned index;
  uint64_t bits[PAGE_BITS / 64];
} HitPage;

typedef struct HitSource {
  struct HitSource *next;
  TString *source;
  HitPage *pages;
  HitPage *last_page;
} HitSource;

typedef struct Collector {
  HitSource *buckets[SOURCE_BUCKETS];
  HitSource *last_source;
  int active;
} Collector;

static char collector_key;

/* The collector's uservalues: the source strings it roots, the C
 * functions a call is counted for (nil when none are), and the names of
 * the ones called since `start`. */
#define ROOTED 1
#define WATCHED 2
#define CALLED 3

/* Installed before any Lua code runs (cosmic_surface_open). Lua copies the
 * main thread's extraspace into new coroutines. Keep this userdata rooted and
 * at a stable address for the entire state's lifetime, across all sessions. */
_Static_assert(LUA_EXTRASPACE >= sizeof(Collector *), "coverage needs a pointer");

static Collector *current_collector(lua_State *L) {
  Collector *collector;
  memcpy(&collector, lua_getextraspace(L), sizeof(collector));
  return collector;
}

static void collector_clear(Collector *collector) {
  collector->active = 0;
  for (unsigned i = 0; i < SOURCE_BUCKETS; i++) {
    HitSource *source = collector->buckets[i];
    while (source) {
      HitSource *next = source->next;
      HitPage *page = source->pages;
      while (page) {
        HitPage *next_page = page->next;
        free(page);
        page = next_page;
      }
      free(source);
      source = next;
    }
    collector->buckets[i] = NULL;
  }
  collector->last_source = NULL;
}

static int collector_gc(lua_State *L) {
  collector_clear(lua_touserdata(L, 1));
  return 0;
}

static void native_line_hook(lua_State *L, lua_Debug *ar) {
  Collector *collector = current_collector(L);
  /* A coroutine can retain an inherited hook after its parent stops. */
  if (!collector || !collector->active || ar->currentline < 0) {
    return;
  }
  TString *name = clLvalue(s2v(ar->i_ci->func.p))->p->source;
  HitSource *source = collector->last_source;
  if (!source || source->source != name) {
    unsigned bucket = ((uintptr_t)name >> 3) % SOURCE_BUCKETS;
    for (source = collector->buckets[bucket]; source; source = source->next) {
      if (source->source == name) break;
    }
    if (!source) {
      /* Root only the original TString, not its closure and captured values.
       * Long strings are not interned: copying one would leave this pointer
       * unrooted. Pointer keys keep equal-but-distinct strings rooted too. */
      if (name) {
        lua_rawgetp(L, LUA_REGISTRYINDEX, &collector_key);
        lua_getiuservalue(L, -1, ROOTED);
        lua_pushlightuserdata(L, name);
        setsvalue2s(L, L->top.p, name);
        api_incr_top(L);
        lua_rawset(L, -3);
        lua_pop(L, 2);
      }
      source = calloc(1, sizeof(*source));
      if (!source) luaL_error(L, "coverage: out of memory");
      source->source = name;
      source->next = collector->buckets[bucket];
      collector->buckets[bucket] = source;
    }
    collector->last_source = source;
  }
  unsigned line = (unsigned)ar->currentline;
  unsigned index = line / PAGE_BITS;
  HitPage *page = source->last_page;
  if (!page || page->index != index) {
    for (page = source->pages; page; page = page->next) {
      if (page->index == index) break;
    }
    if (!page) {
      page = calloc(1, sizeof(*page));
      if (!page) luaL_error(L, "coverage: out of memory");
      page->index = index;
      page->next = source->pages;
      source->pages = page;
    }
    source->last_page = page;
  }
  unsigned offset = line % PAGE_BITS;
  page->bits[offset / 64] |= UINT64_C(1) << (offset % 64);
}

/* called[watched[f]] = true, when the function being called is a C
 * function `start` was asked to watch. A C function has no lines for the
 * line hook to see, so this is how a test is seen to reach one. Anything
 * that is not a C function goes back before a table is touched: most
 * calls are Lua's own. */
static void record_call(lua_State *L, lua_Debug *ar) {
  int top = lua_gettop(L);
  if (lua_getinfo(L, "f", ar) && lua_iscfunction(L, -1)) {
    lua_rawgetp(L, LUA_REGISTRYINDEX, &collector_key);
    if (lua_getiuservalue(L, -1, WATCHED) == LUA_TTABLE) {
      lua_pushvalue(L, top + 1);
      if (lua_rawget(L, -2) == LUA_TSTRING) {
        lua_getiuservalue(L, top + 2, CALLED);
        lua_pushvalue(L, -2);
        lua_pushboolean(L, 1);
        lua_rawset(L, -3);
      }
    }
  }
  lua_settop(L, top);
}

static void native_hook(lua_State *L, lua_Debug *ar) {
  if (ar->event == LUA_HOOKLINE) {
    native_line_hook(L, ar);
    return;
  }
  Collector *collector = current_collector(L);
  if (collector && collector->active) {
    record_call(L, ar);
  }
}

/* start(watched?): `watched` maps C functions to the names `called`
 * reports them under. Without it only lines are hooked, and a call
 * costs nothing. */
static int coverage_start(lua_State *L) {
  int watching = !lua_isnoneornil(L, 1);
  if (watching) {
    luaL_checktype(L, 1, LUA_TTABLE);
  }
  Collector *collector = current_collector(L);
  collector_clear(collector);
  lua_rawgetp(L, LUA_REGISTRYINDEX, &collector_key);
  lua_newtable(L);
  lua_setiuservalue(L, -2, ROOTED);
  if (watching) {
    lua_pushvalue(L, 1);
  } else {
    lua_pushnil(L);
  }
  lua_setiuservalue(L, -2, WATCHED);
  lua_newtable(L);
  lua_setiuservalue(L, -2, CALLED);
  lua_pop(L, 1);
  collector->active = 1;
  lua_sethook(L, native_hook, LUA_MASKLINE | (watching ? LUA_MASKCALL : 0), 0);
  return 0;
}

/* called(): the name of every watched function called since `start`, as
 * a fresh {name = true} table. */
static int coverage_called(lua_State *L) {
  lua_newtable(L);
  lua_rawgetp(L, LUA_REGISTRYINDEX, &collector_key);
  if (lua_getiuservalue(L, -1, CALLED) == LUA_TTABLE) {
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
      lua_pushvalue(L, -2);
      lua_insert(L, -2);
      lua_rawset(L, -6);
    }
  }
  lua_pop(L, 2);
  return 1;
}

/* Materialize fresh tables only when requested. Separate Lua source strings
 * may contain the same name; their hit sets must be merged, not overwritten.
 * Sparse pages bound storage even for chunks with very high line numbers. */
static int coverage_snapshot(lua_State *L) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &collector_key);
  Collector *collector = lua_touserdata(L, -1);
  lua_newtable(L);
  if (!collector) return 1;
  int hits = lua_gettop(L);
  for (unsigned i = 0; i < SOURCE_BUCKETS; i++) {
    for (HitSource *source = collector->buckets[i]; source; source = source->next) {
      const char *name = source->source ? getstr(source->source) : "=?";
      size_t length = source->source ? tsslen(source->source) : 2;
      if (length > 0 && name[0] == '@') { name++; length--; }
      lua_pushlstring(L, name, length);
      lua_rawget(L, hits);
      if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushlstring(L, name, length);
        lua_pushvalue(L, -2);
        lua_rawset(L, hits);
      }
      for (HitPage *page = source->pages; page; page = page->next) {
        for (unsigned word = 0; word < PAGE_BITS / 64; word++) {
          uint64_t bits = page->bits[word];
          if (!bits) continue;
          for (unsigned bit = 0; bit < 64; bit++) {
            if (bits & (UINT64_C(1) << bit)) {
              lua_pushboolean(L, 1);
              lua_rawseti(L, -2, (lua_Integer)page->index * PAGE_BITS + word * 64 + bit);
            }
          }
        }
      }
      lua_pop(L, 1);
    }
  }
  return 1;
}

static int coverage_stop(lua_State *L) {
  lua_sethook(L, NULL, 0, 0);
  lua_rawgetp(L, LUA_REGISTRYINDEX, &collector_key);
  Collector *collector = lua_touserdata(L, -1);
  if (collector) collector->active = 0;
  lua_pop(L, 1);
  return coverage_snapshot(L);
}

void cosmic_coverage_install(lua_State *L) {
  luaL_newmetatable(L, "cosmic.coverage.collector");
  lua_pushcfunction(L, collector_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  Collector *collector = lua_newuserdatauv(L, sizeof(*collector), 3);
  *collector = (Collector){0};
  luaL_setmetatable(L, "cosmic.coverage.collector");
  lua_newtable(L);
  lua_setiuservalue(L, -2, ROOTED);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &collector_key);
  memcpy(lua_getextraspace(L), &collector, sizeof(collector));
  lua_newtable(L);
  lua_pushcfunction(L, coverage_start);
  lua_setfield(L, -2, "start");
  lua_pushcfunction(L, coverage_stop);
  lua_setfield(L, -2, "stop");
  lua_pushcfunction(L, coverage_snapshot);
  lua_setfield(L, -2, "snapshot");
  lua_pushcfunction(L, coverage_called);
  lua_setfield(L, -2, "called");
}
