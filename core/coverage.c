#define _POSIX_C_SOURCE 200809L

#include "coverage.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lapi.h"
/* setsvalue2s checks the string is live when Lua is built with its own
 * assertions (LUAI_ASSERT), and that check is lgc.h's isdead. */
#include "lgc.h"
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
  /* Collecting since the state was made, for the first `start` to keep. */
  int from_startup;
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

/* Which blocks' lines `native_collect` adds: every one, those hit since the
 * window opened, or those that begin a function. */
enum native_want { NATIVE_ALL, NATIVE_HIT, NATIVE_ENTRY };

/* The core's own C, observed through clang's sancov: every basic block of
 * the files built with COSMIC_NATIVE_COVERAGE owns one flag byte, which the
 * block's own code sets as it runs, with no call. The flags and the table
 * saying which line each block begins on are both indexed by block, in link
 * order: core/coverage_map.zig reads a first link's debug information and
 * writes the table, and the second link carries it. No runtime work happens
 * per block, so collection is simply clearing the flags when a window opens
 * and reading them when it is read. */
#ifdef COSMIC_NATIVE_COVERAGE
#include <stdbool.h>

void __sanitizer_cov_bool_flag_init(bool *start, bool *stop);
void __sanitizer_cov_pcs_init(const uintptr_t *start, const uintptr_t *stop);

/* The first link carries an empty table (core/coverage_map_empty.c), and
 * is only ever read, never run. */
extern const uint32_t cosmic_native_coverage_blocks;
extern const char *const cosmic_native_coverage_paths[];
extern const uint16_t cosmic_native_coverage_path[];
extern const uint32_t cosmic_native_coverage_line[];
extern const uint8_t cosmic_native_coverage_entry[];

static bool *native_flags;
static size_t native_count;

/* Every instrumented object's constructor calls this with the same, whole
 * section; on a later call it is the same range again. */
void __sanitizer_cov_bool_flag_init(bool *start, bool *stop) {
  native_flags = start;
  native_count = (size_t)(stop - start);
}

/* The PC table is only ever read from the file, by the map generator. */
void __sanitizer_cov_pcs_init(const uintptr_t *start, const uintptr_t *stop) {
  (void)start;
  (void)stop;
}

/* A table from another link would put hits on the wrong lines, so a
 * mismatch is an error rather than an empty answer. */
static int native_ready(lua_State *L) {
  if (!native_flags) return 0;
  if (cosmic_native_coverage_blocks != native_count) {
    return luaL_error(L, "coverage: the core's block table does not match its %d blocks",
                      (int)native_count);
  }
  return 1;
}

/* The flags start clear and count from the process's first instruction, so
 * the first window keeps what ran before it opened -- startup, which no
 * window could otherwise see. Every later window starts empty. */
static int native_opened;

static void native_open(void) {
  if (native_opened++ && native_flags) memset(native_flags, 0, native_count);
}

/* Adds to the {path: {line: true}} table at `hits` the line of every mapped
 * block `want` names. */
static void native_collect(lua_State *L, int hits, enum native_want want) {
  if (!native_ready(L)) return;
  for (size_t block = 0; block < native_count; block++) {
    uint16_t path = cosmic_native_coverage_path[block];
    if (path == UINT16_MAX) continue;
    if (want == NATIVE_HIT && !native_flags[block]) continue;
    if (want == NATIVE_ENTRY && !cosmic_native_coverage_entry[block]) continue;
    const char *name = cosmic_native_coverage_paths[path];
    lua_getfield(L, hits, name);
    if (lua_isnil(L, -1)) {
      lua_pop(L, 1);
      lua_newtable(L);
      lua_pushvalue(L, -1);
      lua_setfield(L, hits, name);
    }
    lua_pushboolean(L, 1);
    lua_rawseti(L, -2, (lua_Integer)cosmic_native_coverage_line[block]);
    lua_pop(L, 1);
  }
}
#else
static void native_open(void) {}
static void native_collect(lua_State *L, int hits, enum native_want want) {
  (void)L;
  (void)hits;
  (void)want;
}
#endif

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
      if (!source) {
        luaL_error(L, "coverage: out of memory");
        return;
      }
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
      if (!page) {
        luaL_error(L, "coverage: out of memory");
        return;
      }
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
  /* The first window after startup collection keeps what startup hit,
   * and the source strings rooted for it. */
  int keep = collector->from_startup;
  collector->from_startup = 0;
  if (!keep) collector_clear(collector);
  lua_rawgetp(L, LUA_REGISTRYINDEX, &collector_key);
  if (!keep) {
    lua_newtable(L);
    lua_setiuservalue(L, -2, ROOTED);
  }
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
  native_open();
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
  native_collect(L, hits, NATIVE_HIT);
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

/* Every line of the core's own C that has a block starting on it, hit or
 * not, keyed like `snapshot`: what a hit is out of. Empty in a core built
 * without native coverage. */
static int coverage_lines(lua_State *L) {
  lua_newtable(L);
  native_collect(L, lua_gettop(L), NATIVE_ALL);
  return 1;
}

/* The line each of the core's own C functions begins on, keyed like
 * `lines`: a function is entered when that line is hit. Empty in a core
 * built without native coverage. */
static int coverage_entries(lua_State *L) {
  lua_newtable(L);
  native_collect(L, lua_gettop(L), NATIVE_ENTRY);
  return 1;
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
  /* A test worker's runner asks for the Lua that runs before its first
   * window -- the command line's dispatch and every module it loads --
   * by naming COSMIC_COVERAGE_STARTUP. The name is consumed here, before
   * any Lua runs, so neither the test nor anything it starts sees it. */
  const char *startup = getenv("COSMIC_COVERAGE_STARTUP");
  if (startup && startup[0]) {
    unsetenv("COSMIC_COVERAGE_STARTUP");
    collector->active = 1;
    collector->from_startup = 1;
    lua_sethook(L, native_hook, LUA_MASKLINE, 0);
  }
  lua_newtable(L);
  lua_pushcfunction(L, coverage_start);
  lua_setfield(L, -2, "start");
  lua_pushcfunction(L, coverage_stop);
  lua_setfield(L, -2, "stop");
  lua_pushcfunction(L, coverage_snapshot);
  lua_setfield(L, -2, "snapshot");
  lua_pushcfunction(L, coverage_called);
  lua_setfield(L, -2, "called");
  lua_pushcfunction(L, coverage_lines);
  lua_setfield(L, -2, "lines");
  lua_pushcfunction(L, coverage_entries);
  lua_setfield(L, -2, "entries");
}
