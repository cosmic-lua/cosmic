#define _POSIX_C_SOURCE 200809L

#include "coverage.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "check.h"
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
  /* VM instructions `budget` allows before it raises, or 0 when unarmed.
   * It shares the one hook slot with collection, so both are always
   * installed together (`install_hook`). */
  int budget;
} Collector;

static char collector_key;

/* What a spent `budget` raises, exactly: a caught value equal to it is
 * the budget's, never a program's own error. */
#define BUDGET_MESSAGE "instruction budget exceeded"

/* The collector's uservalue: the source strings it roots. */
#define ROOTED 1

/* Installed before any Lua code runs (cosmic_surface_open). Lua copies the
 * main thread's extraspace into new coroutines. Keep this userdata rooted and
 * at a stable address for the entire state's lifetime, across all sessions. */
_Static_assert(LUA_EXTRASPACE >= sizeof(Collector *), "coverage needs a pointer");

static Collector *current_collector (lua_State *L) {
  Collector *collector;
  memcpy(&collector, lua_getextraspace(L), sizeof(collector));
  return collector;
}

static void collector_clear (Collector *collector) {
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

static int collector_gc (lua_State *L) {
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

void __sanitizer_cov_bool_flag_init (bool *start, bool *stop);
void __sanitizer_cov_pcs_init (const uintptr_t *start, const uintptr_t *stop);

/* The first link carries an empty table (core/coverage_map_empty.c), and
 * is only ever read, never run. */
extern const uint32_t cosmic_native_coverage_blocks;
extern const char *const cosmic_native_coverage_paths[];
extern const uint16_t cosmic_native_coverage_path[];
extern const uint32_t cosmic_native_coverage_line[];
extern const uint8_t cosmic_native_coverage_entry[];
extern const char *const cosmic_native_coverage_function[];

static bool *native_flags;
static size_t native_count;

/* Every instrumented object's constructor calls this with the same, whole
 * section; on a later call it is the same range again. */
void __sanitizer_cov_bool_flag_init (bool *start, bool *stop) {
  native_flags = start;
  native_count = (size_t)(stop - start);
}

/* The PC table is only ever read from the file, by the map generator. */
void __sanitizer_cov_pcs_init (const uintptr_t *start, const uintptr_t *stop) {
  (void)start;
  (void)stop;
}

/* A table from another link would put hits on the wrong lines, so a
 * mismatch is an error rather than an empty answer. */
static int native_ready (lua_State *L) {
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

/* Every block a process that reports to a test has hit, across the
 * windows it opens itself (a nested test run's): allocated only then. */
static bool *native_ever;

static void native_open (void) {
  if (native_opened++ && native_flags) {
    if (native_ever) {
      for (size_t block = 0; block < native_count; block++) native_ever[block] |= native_flags[block];
    }
    memset(native_flags, 0, native_count);
  }
}

/* Adds to the {path: {line: true}} table at `hits` the line of every mapped
 * block `want` names. */
static void native_collect (lua_State *L, int hits, enum native_want want) {
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
static void native_open (void) {}
static void native_collect (lua_State *L, int hits, enum native_want want) {
  (void)L;
  (void)hits;
  (void)want;
}
#endif

/* A process a test starts reports the C it ran to a directory that test's
 * worker names, so it counts for the test (build/test_worker.tl). The
 * directory travels as COSMIC_COVERAGE_CHILDREN in every environment the
 * core starts a process with, whatever environment the program gave it,
 * and is taken out of this process's own before any Lua runs: a program
 * never sees it, and a verdict's key never holds it. */
#define CHILDREN_NAME "COSMIC_COVERAGE_CHILDREN"
static char *children_entry; /* CHILDREN_NAME "=" directory, or NULL */
static int reports;          /* this process is one a test started */

static int set_children (const char *directory) {
  size_t size = sizeof CHILDREN_NAME + 1 + strlen(directory);
  char *entry = malloc(size);
  if (!entry) return 0;
  snprintf(entry, size, "%s=%s", CHILDREN_NAME, directory);
  free(children_entry);
  children_entry = entry;
  return 1;
}

char **cosmic_coverage_environment (char **envp) {
  if (!children_entry) return envp;
  size_t count = 0;
  size_t name = sizeof CHILDREN_NAME; /* with its '=' in place of the NUL */
  for (; envp[count]; count++) {
    if (strncmp(envp[count], children_entry, name) == 0) return envp;
  }
  char **given = malloc((count + 2) * sizeof *given);
  if (!given) return envp; /* the child goes unreported rather than unstarted */
  memcpy(given, envp, count * sizeof *given);
  given[count] = children_entry;
  given[count + 1] = NULL;
  return given;
}

void cosmic_coverage_report (void) {
#ifdef COSMIC_NATIVE_COVERAGE
  static unsigned reported; /* a process can report more than once: before a failed execve */
  if (!reports || !native_flags || cosmic_native_coverage_blocks != native_count) return;
  char path[4096];
  int length = snprintf(path, sizeof path, "%s/%ld.%u", children_entry + sizeof CHILDREN_NAME,
                        (long)getpid(), reported++);
  if (length < 0 || (size_t)length >= sizeof path) return;
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  if (fd < 0) return;
  /* One "path TAB line" per hit block; a line hit twice is read once. */
  char buffer[8192];
  size_t used = 0;
  for (size_t block = 0; block <= native_count; block++) {
    int last = block == native_count;
    if (!last) {
      uint16_t file = cosmic_native_coverage_path[block];
      int hit = native_flags[block] || (native_ever && native_ever[block]);
      if (file == UINT16_MAX || !hit) continue;
      int wrote = snprintf(buffer + used, sizeof buffer - used, "%s\t%u\n",
                           cosmic_native_coverage_paths[file],
                           (unsigned)cosmic_native_coverage_line[block]);
      if (wrote < 0) break;
      if ((size_t)wrote < sizeof buffer - used) {
        used += (size_t)wrote;
        continue;
      }
      block--; /* did not fit: flush, then write this block again */
    }
    for (size_t at = 0; at < used;) {
      ssize_t written = write(fd, buffer + at, used - at);
      if (written <= 0) {
        close(fd);
        return;
      }
      at += (size_t)written;
    }
    used = 0;
  }
  close(fd);
#endif
}

static void install_hook (lua_State *L, Collector *collector);

/* The budget ran out: disarm it before raising, so nothing the unwinding
 * runs is counted against it again. A coroutine made while it was armed
 * keeps its inherited count after a disarm; its later counts find the
 * budget unarmed and do nothing. */
static void budget_hook (lua_State *L, Collector *collector) {
  if (!collector || collector->budget == 0) return;
  collector->budget = 0;
  install_hook(L, collector);
  lua_pushliteral(L, BUDGET_MESSAGE);
  lua_error(L);
}

static void native_line_hook (lua_State *L, lua_Debug *ar) {
  Collector *collector = current_collector(L);
  if (ar->event == LUA_HOOKCOUNT) {
    budget_hook(L, collector);
    return;
  }
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

/* The one hook slot carries lines while collecting and a count while a
 * budget is armed; with neither it is cleared. */
static void install_hook (lua_State *L, Collector *collector) {
  int mask = 0;
  int count = 0;
  if (collector && collector->active) mask |= LUA_MASKLINE;
  if (collector && collector->budget > 0) {
    mask |= LUA_MASKCOUNT;
    count = collector->budget;
  }
  lua_sethook(L, mask ? native_line_hook : NULL, mask, count);
}

/* start(): hooks lines and begins a collection. */
static int coverage_start (lua_State *L) {
  Collector *collector = current_collector(L);
  /* The first window after startup collection keeps what startup hit,
   * and the source strings rooted for it. */
  int keep = collector->from_startup;
  collector->from_startup = 0;
  if (!keep) {
    collector_clear(collector);
    lua_rawgetp(L, LUA_REGISTRYINDEX, &collector_key);
    lua_newtable(L);
    lua_setiuservalue(L, -2, ROOTED);
    lua_pop(L, 1);
  }
  collector->active = 1;
  native_open();
  install_hook(L, collector);
  return 0;
}

/* Materialize fresh tables only when requested. Separate Lua source strings
 * may contain the same name; their hit sets must be merged, not overwritten.
 * Sparse pages bound storage even for chunks with very high line numbers. */
static int coverage_snapshot (lua_State *L) {
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

static int coverage_stop (lua_State *L) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &collector_key);
  Collector *collector = lua_touserdata(L, -1);
  if (collector) collector->active = 0;
  install_hook(L, collector);
  lua_pop(L, 1);
  return coverage_snapshot(L);
}

/* budget([count]): arms a budget of `count` VM instructions on the calling
 * thread, and on every coroutine it makes while armed; spending them
 * raises BUDGET_MESSAGE. With no count, or 0, disarms. Collection is
 * unaffected either way: both share the one hook. A hang inside a single
 * C call is out of its reach, since the count runs between instructions. */
static int coverage_budget (lua_State *L) {
  int count = cosmic_optint(L, 1, 0);
  luaL_argcheck(L, count >= 0, 1, "is negative");
  Collector *collector = current_collector(L);
  if (!collector) return 0;
  collector->budget = count;
  install_hook(L, collector);
  return 0;
}

/* Every line of the core's own C that has a block starting on it, hit or
 * not, keyed like `snapshot`: what a hit is out of. Empty in a core built
 * without native coverage. */
static int coverage_lines (lua_State *L) {
  lua_newtable(L);
  native_collect(L, lua_gettop(L), NATIVE_ALL);
  return 1;
}

/* functions(): every one of the core's own C functions, as a sequence of
 * {path =, line =, name =}: its file by repository path, the line it
 * begins on (an `entries` line), and its name. Empty in a core built
 * without native coverage. */
static int coverage_functions (lua_State *L) {
  lua_newtable(L);
#ifdef COSMIC_NATIVE_COVERAGE
  if (!native_ready(L)) return 1;
  lua_Integer at = 0;
  for (size_t block = 0; block < native_count; block++) {
    uint16_t path = cosmic_native_coverage_path[block];
    const char *name = cosmic_native_coverage_function[block];
    if (path == UINT16_MAX || !cosmic_native_coverage_entry[block] || !name) continue;
    lua_createtable(L, 0, 3);
    lua_pushstring(L, cosmic_native_coverage_paths[path]);
    lua_setfield(L, -2, "path");
    lua_pushinteger(L, (lua_Integer)cosmic_native_coverage_line[block]);
    lua_setfield(L, -2, "line");
    lua_pushstring(L, name);
    lua_setfield(L, -2, "name");
    lua_rawseti(L, -2, ++at);
  }
#endif
  return 1;
}

/* children(directory): every process this one starts from now on, and
 * every one those start, reports the C it ran there as it exits. */
static int coverage_children (lua_State *L) {
  if (!set_children(luaL_checkstring(L, 1))) return luaL_error(L, "coverage: out of memory");
  return 0;
}

/* The line each of the core's own C functions begins on, keyed like
 * `lines`: a function is entered when that line is hit. Empty in a core
 * built without native coverage. */
static int coverage_entries (lua_State *L) {
  lua_newtable(L);
  native_collect(L, lua_gettop(L), NATIVE_ENTRY);
  return 1;
}

void cosmic_coverage_prepare (void) {
  const char *children = getenv(CHILDREN_NAME);
  if (children && children[0] && !reports && set_children(children)) {
    unsetenv(CHILDREN_NAME);
    reports = 1;
#ifdef COSMIC_NATIVE_COVERAGE
    if (native_count) native_ever = calloc(native_count, 1);
#endif
    atexit(cosmic_coverage_report);
  }
}

void cosmic_coverage_install (lua_State *L) {
  luaL_newmetatable(L, "cosmic.coverage.collector");
  lua_pushcfunction(L, collector_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  Collector *collector = lua_newuserdatauv(L, sizeof(*collector), 1);
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
    install_hook(L, collector);
  }
  cosmic_coverage_prepare();
  lua_newtable(L);
  lua_pushcfunction(L, coverage_start);
  lua_setfield(L, -2, "start");
  lua_pushcfunction(L, coverage_stop);
  lua_setfield(L, -2, "stop");
  lua_pushcfunction(L, coverage_snapshot);
  lua_setfield(L, -2, "snapshot");
  lua_pushcfunction(L, coverage_lines);
  lua_setfield(L, -2, "lines");
  lua_pushcfunction(L, coverage_entries);
  lua_setfield(L, -2, "entries");
  lua_pushcfunction(L, coverage_children);
  lua_setfield(L, -2, "children");
  lua_pushcfunction(L, coverage_functions);
  lua_setfield(L, -2, "functions");
}

int cosmic_open_budget (lua_State *L) {
  lua_createtable(L, 0, 1);
  lua_pushcfunction(L, coverage_budget);
  lua_setfield(L, -2, "budget");
  return 1;
}
