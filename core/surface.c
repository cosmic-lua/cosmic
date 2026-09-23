#include "surface.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#define COSMIC_USABLE_SIZE(block) malloc_size(block)
#else
#include <malloc.h>
#define COSMIC_USABLE_SIZE(block) malloc_usable_size(block)
#endif

#include "check.h"
#include "coverage.h"
#include "lauxlib.h"
#include "lualib.h"
#include "store.h"
#include "syscalls.h"
#include "testing.h"

/* A name that was removed says what took its place, at the site that
 * reached for it, rather than in a document somewhere else. */
struct replacement {
  const char *name;
  const char *hint;
};

static const struct replacement replacements[] = {
    {"io", "io is not available: files are cosmic.fs, and the standard "
           "streams are cosmic.fs.stdout, .stderr and .stdin"},
    {"os", "os is not available: time is cosmic.time, the environment is "
           "cosmic.env, and processes are cosmic.proc"},
    {"debug", "debug is not available: a traceback is cosmic.errors.trace"},
    {"dofile", "dofile is not available: a module comes from require, and "
               "a file's bytes come from cosmic.fs.read"},
    {"loadfile", "loadfile is not available: a module comes from require, "
                 "and a file's bytes come from cosmic.fs.read"},
    {"require", NULL},
    {NULL, NULL},
};

/* `print` over the syscall table, so every byte the process writes goes
 * through one door. Each argument's text is pushed above the open
 * buffer, so it goes in with luaL_addvalue: every other buffer call
 * needs the buffer's own slot on top, and once the line outgrows the
 * buffer's inline room that slot is a heap box a stray pop would free. */
static int surface_print(lua_State *L) {
  int count = lua_gettop(L);
  luaL_Buffer line;
  luaL_buffinit(L, &line);
  for (int i = 1; i <= count; i++) {
    if (i > 1) {
      luaL_addchar(&line, '\t');
    }
    luaL_tolstring(L, i, NULL);
    luaL_addvalue(&line);
  }
  luaL_addchar(&line, '\n');
  luaL_pushresult(&line);

  size_t len;
  const char *text = lua_tolstring(L, -1, &len);
  size_t at = 0;
  while (at < len) {
    ssize_t put = write(STDOUT_FILENO, text + at, len - at);
    if (put < 0) {
      if (errno == EINTR) {
        continue;
      }
      return luaL_error(L, "print: %s", strerror(errno));
    }
    at += (size_t)put;
  }
  lua_pop(L, 1);
  return 0;
}

/* A traceback built from Lua's internal debugging support: a program
 * reporting a failure needs to say where it happened. */
static int surface_trace(lua_State *L) {
  const char *message = luaL_optstring(L, 1, NULL);
  int level = cosmic_optint(L, 2, 1);
  luaL_traceback(L, L, message, level);
  return 1;
}

static int open_errors(lua_State *L) {
  lua_createtable(L, 0, 1);
  lua_pushcfunction(L, surface_trace);
  lua_setfield(L, -2, "trace");
  return 1;
}

/* Raised when a program reaches for a name this surface removed. */
static int surface_missing(lua_State *L) {
  const char *name = lua_tostring(L, 2);
  lua_getfield(L, lua_upvalueindex(1), name == NULL ? "" : name);
  if (lua_isstring(L, -1)) {
    return lua_error(L);
  }
  lua_pop(L, 1);
  lua_pushnil(L);
  return 1;
}

static void open_library(lua_State *L, const char *name, lua_CFunction opener,
                         int global) {
  luaL_requiref(L, name, opener, global);
  lua_pop(L, 1);
}

static void clear_field(lua_State *L, const char *table, const char *field) {
  lua_getglobal(L, table);
  lua_pushnil(L);
  lua_setfield(L, -2, field);
  lua_pop(L, 1);
}

/*
 * The state's allocator: the C library's, with a few freed big blocks
 * kept for the next allocation of their size. musl hands a block past
 * 32 KiB to the kernel and back on every allocation and free, so a loop
 * of 64 KiB strings -- the chunk every stream reads in -- pays an mmap
 * and an munmap per string, and runs at a sixth of the speed of one at
 * 24 KiB. A block from 32 KiB to 2 MiB is rounded up to one of four
 * sizes per power of two, and a freed one is kept instead of freed --
 * enough per size for the dozens a collection frees at once, and 8 MiB
 * in all. Everything else, and anything the cache has no room for, is
 * plain malloc, realloc and free.
 *
 * A block is filed under the largest size its C library says it can
 * hold, never under the size Lua asked for, so a block that came from
 * anywhere -- realloc, or luaL_newstate's own allocator before this one
 * replaced it -- is only ever handed out for as much as it holds.
 */
#define CACHE_SIZES 24         /* 40, 48, 56, 64, 80, ... 2048 KiB */
#define CACHE_DEPTH 64         /* blocks kept per size */
#define CACHE_BUDGET (8 << 20) /* bytes kept in all */

static struct {
  void *blocks[CACHE_SIZES][CACHE_DEPTH];
  size_t usable[CACHE_SIZES][CACHE_DEPTH];
  int count[CACHE_SIZES];
  size_t bytes;
} cache;

/* The size of cache entry `i`: five to eight eighths of a power of two. */
static size_t cache_size(int i) {
  return (size_t)(5 + i % 4) << (13 + i / 4);
}

/* The smallest entry that holds `n` bytes, or -1 when `n` is not a size
 * the cache keeps. */
static int cache_fit(size_t n) {
  if (n <= ((size_t)32 << 10) || n > cache_size(CACHE_SIZES - 1)) return -1;
  int i = 0;
  while (cache_size(i) < n) i++;
  return i;
}

/* The largest entry a block of `usable` bytes can stand for, or -1. */
static int cache_floor(size_t usable) {
  if (usable < cache_size(0) || usable > 2 * cache_size(CACHE_SIZES - 1))
    return -1;
  int i = CACHE_SIZES - 1;
  while (cache_size(i) > usable) i--;
  return i;
}

static void cache_release(void *block) {
  if (block == NULL) return;
  size_t usable = COSMIC_USABLE_SIZE(block);
  int i = cache_floor(usable);
  if (i >= 0 && cache.count[i] < CACHE_DEPTH &&
      cache.bytes + usable <= CACHE_BUDGET) {
    cache.blocks[i][cache.count[i]] = block;
    cache.usable[i][cache.count[i]] = usable;
    cache.count[i]++;
    cache.bytes += usable;
    return;
  }
  free(block);
}

static void *cache_take(int i) {
  if (cache.count[i] == 0) return malloc(cache_size(i));
  cache.count[i]--;
  cache.bytes -= cache.usable[i][cache.count[i]];
  return cache.blocks[i][cache.count[i]];
}

static void *cached_alloc(void *unused, void *block, size_t osize,
                          size_t nsize) {
  (void)unused;
  if (nsize == 0) {
    cache_release(block);
    return NULL;
  }
  int fit = cache_fit(nsize);
  if (fit < 0) return realloc(block, nsize);
  /* With block NULL, osize names the kind of object, not a size. */
  if (block == NULL) return cache_take(fit);
  if (cache_floor(COSMIC_USABLE_SIZE(block)) == fit) return block;
  void *moved = cache_take(fit);
  if (moved == NULL) return realloc(block, nsize);
  memcpy(moved, block, osize < nsize ? osize : nsize);
  cache_release(block);
  return moved;
}

void cosmic_surface_close(lua_State *L) {
  lua_close(L);
  for (int i = 0; i < CACHE_SIZES; i++) {
    while (cache.count[i] > 0) free(cache_take(i));
  }
}

lua_State *cosmic_surface_open(const char *logical_executable) {
  lua_State *L = luaL_newstate();
  if (L == NULL) {
    return NULL;
  }
  /* lauxlib's own state keeps its panic and warning handlers; only the
   * allocator changes, before anything but the state itself is made. */
  lua_setallocf(L, cached_alloc, NULL);

  if (logical_executable != NULL) {
    lua_pushstring(L, logical_executable);
    lua_setfield(L, LUA_REGISTRYINDEX, COSMIC_LOGICAL_EXECUTABLE);
  }

  open_library(L, LUA_GNAME, luaopen_base, 1);
  open_library(L, LUA_LOADLIBNAME, luaopen_package, 1);
  open_library(L, LUA_COLIBNAME, luaopen_coroutine, 1);
  open_library(L, LUA_TABLIBNAME, luaopen_table, 1);
  open_library(L, LUA_STRLIBNAME, luaopen_string, 1);
  open_library(L, LUA_MATHLIBNAME, luaopen_math, 1);
  open_library(L, LUA_UTF8LIBNAME, luaopen_utf8, 1);

  /* The native coverage collector hooks lines in C and is exposed only
   * through the store searcher's trust-gated internal module. */
  cosmic_coverage_install(L);
  cosmic_store_set_raw(L, "cosmic.internal.debug");

  lua_pushnil(L);
  lua_setglobal(L, "dofile");
  lua_pushnil(L);
  lua_setglobal(L, "loadfile");

  /* A file path never resolves to a module: the database is the only
   * module source, and the searcher that reads it is installed later. */
  clear_field(L, LUA_LOADLIBNAME, "path");
  clear_field(L, LUA_LOADLIBNAME, "cpath");
  clear_field(L, LUA_LOADLIBNAME, "loadlib");
  clear_field(L, LUA_LOADLIBNAME, "searchpath");

  lua_pushcfunction(L, surface_print);
  lua_setglobal(L, "print");

  lua_getfield(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, cosmic_open_syscalls);
  lua_setfield(L, -2, "cosmic.sys");
  lua_pushcfunction(L, open_errors);
  lua_setfield(L, -2, "cosmic.internal.errors");
  lua_pushcfunction(L, cosmic_open_testing);
  lua_setfield(L, -2, "cosmic.internal.testing");
  lua_pop(L, 1);

  lua_newtable(L);
  for (const struct replacement *r = replacements; r->name != NULL; r++) {
    if (r->hint == NULL) {
      continue;
    }
    lua_pushstring(L, r->hint);
    lua_setfield(L, -2, r->name);
  }
  lua_pushglobaltable(L);
  lua_newtable(L);
  lua_pushvalue(L, -3);
  lua_pushcclosure(L, surface_missing, 1);
  lua_setfield(L, -2, "__index");
  lua_setmetatable(L, -2);
  lua_pop(L, 2);

  return L;
}
