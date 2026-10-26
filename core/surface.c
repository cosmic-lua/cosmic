#include "surface.h"

#include <errno.h>
#include <stdbool.h>
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
#include "errnos.h"
#include "lauxlib.h"
#include "lualib.h"
#include "store.h"
#include "syscalls.h"
#include "testing.h"

/* The names this surface removed. Each says what took its place, at
 * the site that reached for it, rather than in a document somewhere
 * else -- and for io, os and debug, what took the place of the very
 * field used: reading one gives a stand-in table whose every field
 * raises. The words come from cosmic.removed's `message`, the same
 * function a compile refused for the same name quotes, so the two
 * cannot drift apart. */
struct removed {
  const char *name;
  bool fields;
};

static const struct removed removed_names[] = {
  {"io", true},        {"os", true},        {"debug", true},
  {"dofile", false},   {"loadfile", false}, {NULL, false},
};

/* `print`, writing its line to standard output with write(2) directly
 * rather than through Lua's buffered stdio. Each argument's text is
 * pushed above the open buffer, so it goes in with luaL_addvalue: every
 * other buffer call needs the buffer's own slot on top, and once the
 * line outgrows the buffer's inline room that slot is a heap box a
 * stray pop would free. */
static int surface_print (lua_State *L) {
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
      return luaL_error(L, "print: %s", cosmic_errno_describe(errno, NULL));
    }
    at += (size_t)put;
  }
  lua_pop(L, 1);
  return 0;
}

/* A traceback built from Lua's internal debugging support: a program
 * reporting a failure needs to say where it happened. */
static int surface_trace (lua_State *L) {
  const char *message = luaL_optstring(L, 1, NULL);
  int level = cosmic_optint(L, 2, 1);
  luaL_traceback(L, L, message, level);
  return 1;
}

/* The traceback of the coroutine at 1, from its top: where one that
 * raised stopped, of which `coroutine.resume` answers only the error.
 * The running coroutine's starts at the frame `level` (argument 3,
 * default 1) counts up from the binding, 1 being its caller as in
 * `trace`; another's is from its top. */
static int surface_trace_of (lua_State *L) {
  luaL_checktype(L, 1, LUA_TTHREAD);
  lua_State *co = lua_tothread(L, 1);
  const char *message = luaL_optstring(L, 2, NULL);
  int level = cosmic_optint(L, 3, 1);
  luaL_traceback(L, co, message, co == L ? level : 0);
  return 1;
}

/* The place of the Lua frame at or above `level` (argument 1, default 1,
 * the binding's caller as in `trace`): "source:line" of the first frame from
 * there that is running a Lua function, or nil where the stack holds none.
 * A caller that must name where a value came from asks this, which costs a
 * frame and not the traceback `trace` builds. */
static int surface_where (lua_State *L) {
  int level = cosmic_optint(L, 1, 1);
  lua_Debug ar;
  while (lua_getstack(L, level, &ar)) {
    lua_getinfo(L, "Sl", &ar);
    if (ar.currentline > 0) {
      lua_pushfstring(L, "%s:%d", ar.short_src, ar.currentline);
      return 1;
    }
    level++;
  }
  lua_pushnil(L);
  return 1;
}

/* `table`, answering the table of the program's globals, which `load`
 * takes as the environment of a chunk that needs all of them. */
static int globals_table (lua_State *L) {
  lua_pushglobaltable(L);
  return 1;
}

static int open_globals (lua_State *L) {
  lua_createtable(L, 0, 1);
  lua_pushcfunction(L, globals_table);
  lua_setfield(L, -2, "table");
  return 1;
}

static int open_errors (lua_State *L) {
  lua_createtable(L, 0, 3);
  lua_pushcfunction(L, surface_where);
  lua_setfield(L, -2, "where");
  lua_pushcfunction(L, surface_trace);
  lua_setfield(L, -2, "trace");
  lua_pushcfunction(L, surface_trace_of);
  lua_setfield(L, -2, "trace_of");
  return 1;
}

/* cosmic.removed's `message` for the name at index 1 and the field at
 * index 2 (nil for the bare name). */
static int removed_message (lua_State *L) {
  lua_settop(L, 2);
  lua_getglobal(L, "require");
  lua_pushliteral(L, "cosmic.removed");
  lua_call(L, 1, 1);
  lua_getfield(L, -1, "message");
  lua_pushvalue(L, 1);
  lua_pushvalue(L, 2);
  lua_call(L, 2, 1);
  return 1;
}

/* Pushes what to write instead of the removed `name` -- or of its
 * field `field`, when that is a string. When cosmic.removed cannot
 * answer (no module searcher yet, no memory, or a held process whose
 * closure lacks it), the bare fact is pushed instead, naming the field
 * as the catalog's words would. */
static void push_removed (lua_State *L, int name, int field) {
  name = lua_absindex(L, name);
  field = field == 0 ? 0 : lua_absindex(L, field);
  lua_pushcfunction(L, removed_message);
  lua_pushvalue(L, name);
  if (field != 0 && lua_type(L, field) == LUA_TSTRING) {
    lua_pushvalue(L, field);
  } else {
    lua_pushnil(L);
  }
  if (lua_pcall(L, 2, 1, 0) != LUA_OK || lua_type(L, -1) != LUA_TSTRING) {
    lua_pop(L, 1);
    lua_pushvalue(L, name);
    if (field != 0 && lua_type(L, field) == LUA_TSTRING) {
      lua_pushliteral(L, ".");
      lua_pushvalue(L, field);
      lua_concat(L, 3);
    }
    lua_pushliteral(L, " is not available");
    lua_concat(L, 2);
  }
}

/* Raises what to write instead of the removed `name` -- or of its
 * field `field` -- at the Lua code that reached for it. */
static _Noreturn void raise_removed (lua_State *L, int name, int field) {
  name = lua_absindex(L, name);
  field = field == 0 ? 0 : lua_absindex(L, field);
  luaL_where(L, 1);
  push_removed(L, name, field);
  lua_concat(L, 2);
  lua_error(L);
  abort(); /* lua_error does not return */
}

bool cosmic_surface_push_removed_library (lua_State *L, const char *name) {
  for (const struct removed *r = removed_names; r->name != NULL; r++) {
    if (r->fields && strcmp(r->name, name) == 0) {
      lua_pushstring(L, name);
      push_removed(L, -1, 0);
      lua_remove(L, -2);
      return true;
    }
  }
  return false;
}

/* A field of a removed library's stand-in, read or written: the
 * library's name is upvalue 1, the field argument 2. */
static int removed_field (lua_State *L) {
  raise_removed(L, lua_upvalueindex(1), 2);
}

/* The stand-in itself, called. */
static int removed_call (lua_State *L) {
  raise_removed(L, lua_upvalueindex(1), 0);
}

/* The fields of `package` the surface removed: a module comes only from
 * the database, so none of them has a use. Each is the name of an entry
 * cosmic.removed's `package.` replacements carry. */
static const char *const removed_package_fields[] = {
  "path", "cpath", "loadlib", "searchpath", NULL,
};

static bool removed_package_field (lua_State *L, int field) {
  if (lua_type(L, field) != LUA_TSTRING) {
    return false;
  }
  const char *name = lua_tostring(L, field);
  for (const char *const *f = removed_package_fields; *f != NULL; f++) {
    if (strcmp(*f, name) == 0) {
      return true;
    }
  }
  return false;
}

/* `package`'s __index, reached for a field the table lacks: one of the
 * removed fields says what to write instead, any other is nil. */
static int package_missing (lua_State *L) {
  if (removed_package_field(L, 2)) {
    lua_pushliteral(L, "package");
    raise_removed(L, -1, 2);
  }
  lua_pushnil(L);
  return 1;
}

/* `package`'s __newindex: a removed field is refused as a read is, and
 * any other field is set as an ordinary table's. */
static int package_assign (lua_State *L) {
  if (removed_package_field(L, 2)) {
    lua_pushliteral(L, "package");
    raise_removed(L, -1, 2);
  }
  lua_settop(L, 3);
  lua_rawset(L, 1);
  return 0;
}

/* Reached when a program reads a global nothing defines: a removed
 * library's stand-in (upvalue 1 maps each such name to one), a removed
 * function's replacement raised, or nil for any other name. */
static int surface_missing (lua_State *L) {
  lua_pushvalue(L, 2);
  lua_rawget(L, lua_upvalueindex(1));
  if (lua_istable(L, -1)) {
    return 1;
  }
  if (lua_toboolean(L, -1)) {
    raise_removed(L, 2, 0);
  }
  lua_pushnil(L);
  return 1;
}

static void open_library (lua_State *L, const char *name, lua_CFunction opener,
                          int global) {
  luaL_requiref(L, name, opener, global);
  lua_pop(L, 1);
}

static void clear_field (lua_State *L, const char *table, const char *field) {
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
static size_t cache_size (int i) {
  return (size_t)(5 + i % 4) << (13 + i / 4);
}

/* The smallest entry that holds `n` bytes, or -1 when `n` is not a size
 * the cache keeps. */
static int cache_fit (size_t n) {
  if (n <= ((size_t)32 << 10) || n > cache_size(CACHE_SIZES - 1)) return -1;
  int i = 0;
  while (cache_size(i) < n) i++;
  return i;
}

/* The largest entry a block of `usable` bytes can stand for, or -1. */
static int cache_floor (size_t usable) {
  if (usable < cache_size(0) || usable > 2 * cache_size(CACHE_SIZES - 1))
    return -1;
  int i = CACHE_SIZES - 1;
  while (cache_size(i) > usable) i--;
  return i;
}

static void cache_release (void *block) {
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

static void *cache_take (int i) {
  if (cache.count[i] == 0) return malloc(cache_size(i));
  cache.count[i]--;
  cache.bytes -= cache.usable[i][cache.count[i]];
  return cache.blocks[i][cache.count[i]];
}

static void *cached_alloc (void *unused, void *block, size_t osize,
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

void cosmic_surface_close (lua_State *L) {
  lua_close(L);
  for (int i = 0; i < CACHE_SIZES; i++) {
    while (cache.count[i] > 0) free(cache_take(i));
  }
}

/* The registry key of the template of the environment `load` gives a
 * chunk it is given none for. */
#define COSMIC_LOAD_ENV "cosmic.load_env"

/* The globals a chunk built by `load` with no environment of its own can
 * read (`print` writes to the host's standard output, as it does for
 * every chunk): the base functions that reach nothing else and share no state
 * with the host (so not `collectgarbage`, which stops or restarts the
 * host's collector, nor `warn`, which switches the host's warnings), and
 * the libraries (copied, below). Neither `require` nor `package` is
 * among them, nor `_G` or `_ENV`, and the table has no metatable, so no
 * path leads from it to either. A program that needs more passes an
 * environment. */
static const char *const load_env_names[] = {
  "assert", "error", "ipairs", "next", "pairs", "pcall", "print",
  "rawequal", "rawget", "rawlen", "rawset", "select", "setmetatable",
  "tonumber", "tostring", "type", "xpcall", "_VERSION", NULL,
};

/* The libraries a chunk reads, each copied for it so that a chunk that
 * assigns into `string` or `table` changes its own and nothing else. */
static const char *const load_env_libraries[] = {
  "coroutine", "math", "string", "table", "utf8", NULL,
};

/* What a copy leaves out: `string.dump`, which makes the binary chunk
 * that crafted bytecode imitates, and `math.random` and
 * `math.randomseed`, whose state is the host's, not the chunk's. (A
 * method call on a string, `("x").dump`, still reaches the host's
 * `string.dump` through the real metatable; that is harmless, since a
 * chunk can load text alone.) */
static const char *const load_env_left_out[][2] = {
  {"string", "dump"}, {"math", "random"}, {"math", "randomseed"}, {NULL, NULL},
};

/* Pushes a copy of the table at `from`, and with `deep` a copy of each
 * table in it too, one level down. */
static void copy_table (lua_State *L, int from, bool deep) {
  from = lua_absindex(L, from);
  lua_createtable(L, 0, 32);
  lua_pushnil(L);
  while (lua_next(L, from) != 0) {
    if (deep && lua_type(L, -1) == LUA_TTABLE) {
      copy_table(L, -1, false);
      lua_remove(L, -2);
    }
    lua_pushvalue(L, -2);
    lua_insert(L, -2);
    lua_rawset(L, -4);
  }
}

/* `getmetatable`, except that the metatable of a string it answers is a
 * copy whose `__index` is a copy of the template's `string`. (A method
 * call on a string, `("x"):rep(2)`, goes through the real metatable to
 * the host's own library, which a chunk cannot reach to change.) Upvalue
 * 1 is Lua's own. */
static int surface_getmetatable (lua_State *L) {
  lua_settop(L, 1);
  if (lua_type(L, 1) == LUA_TSTRING) {
    lua_createtable(L, 0, 1);
    lua_getfield(L, LUA_REGISTRYINDEX, COSMIC_LOAD_ENV);
    lua_getfield(L, -1, "string");
    copy_table(L, -1, false);
    lua_setfield(L, 2, "__index");
    lua_settop(L, 2);
    return 1;
  }
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_insert(L, 1);
  lua_call(L, 1, 1);
  return 1;
}

/* Lua's `load` (upvalue 1), except that a chunk given no environment
 * gets a fresh copy of the template above rather than the globals, and
 * is loaded as text: a binary chunk is code no checker has seen, and
 * only a caller that names its environment may load one. With
 * `always_text` the mode is text whatever the environment, as for the
 * `load` a chunk itself reaches. An environment passed as the fourth
 * argument, nil included, is Lua's own rule. */
static int load_with (lua_State *L, bool always_text) {
  int count = lua_gettop(L);
  if (count < 4 || always_text) {
    if (count < 3) {
      lua_settop(L, 3);
      count = 3;
    }
    lua_pushliteral(L, "t");
    lua_replace(L, 3);
  }
  if (count < 4) {
    lua_getfield(L, LUA_REGISTRYINDEX, COSMIC_LOAD_ENV);
    copy_table(L, -1, true);
    lua_remove(L, -2);
    count = 4;
  }
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_insert(L, 1);
  lua_call(L, count, LUA_MULTRET);
  return lua_gettop(L);
}

static int surface_load (lua_State *L) {
  return load_with(L, false);
}

static int surface_load_text (lua_State *L) {
  return load_with(L, true);
}

/* Replaces the global `load` with surface_load, and makes the template
 * of the environment it gives a chunk, whose libraries are copies made
 * now, so that a later change to the host's does not reach it. The
 * `load` in the template is the text-only one. */
static void install_load (lua_State *L) {
  lua_getglobal(L, "load");
  lua_pushvalue(L, -1);
  lua_pushcclosure(L, surface_load_text, 1);
  lua_createtable(L, 0, 32);
  for (const char *const *name = load_env_names; *name != NULL; name++) {
    lua_getglobal(L, *name);
    lua_setfield(L, -2, *name);
  }
  for (const char *const *name = load_env_libraries; *name != NULL; name++) {
    lua_getglobal(L, *name);
    copy_table(L, -1, false);
    lua_remove(L, -2);
    lua_setfield(L, -2, *name);
  }
  for (int i = 0; load_env_left_out[i][0] != NULL; i++) {
    lua_getfield(L, -1, load_env_left_out[i][0]);
    lua_pushnil(L);
    lua_setfield(L, -2, load_env_left_out[i][1]);
    lua_pop(L, 1);
  }
  lua_getglobal(L, "getmetatable");
  lua_pushcclosure(L, surface_getmetatable, 1);
  lua_setfield(L, -2, "getmetatable");
  lua_pushvalue(L, -2);
  lua_setfield(L, -2, "load");
  lua_setfield(L, LUA_REGISTRYINDEX, COSMIC_LOAD_ENV);
  lua_pop(L, 1);
  lua_pushcclosure(L, surface_load, 1);
  lua_setglobal(L, "load");
}

lua_State *cosmic_surface_open (const char *logical_executable) {
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
  /* No __metatable, as with the stand-ins below and _G's: a program that
   * removes this metatable gets plain nils back. */
  lua_getglobal(L, LUA_LOADLIBNAME);
  lua_createtable(L, 0, 2);
  lua_pushcfunction(L, package_missing);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, package_assign);
  lua_setfield(L, -2, "__newindex");
  lua_setmetatable(L, -2);
  lua_pop(L, 1);

  lua_pushcfunction(L, surface_print);
  lua_setglobal(L, "print");

  lua_getfield(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, cosmic_open_syscalls);
  lua_setfield(L, -2, "cosmic.sys");
  lua_pushcfunction(L, open_errors);
  lua_setfield(L, -2, "cosmic.internal.errors");
  lua_pushcfunction(L, open_globals);
  lua_setfield(L, -2, "cosmic.internal.globals");
  lua_pushcfunction(L, cosmic_open_testing);
  lua_setfield(L, -2, "cosmic.internal.testing");
  lua_pop(L, 1);

  lua_newtable(L);
  for (const struct removed *r = removed_names; r->name != NULL; r++) {
    if (!r->fields) {
      lua_pushboolean(L, 1);
      lua_setfield(L, -2, r->name);
      continue;
    }
    lua_newtable(L); /* the stand-in */
    lua_createtable(L, 0, 3);
    lua_pushstring(L, r->name);
    lua_pushcclosure(L, removed_field, 1);
    lua_setfield(L, -2, "__index");
    lua_pushstring(L, r->name);
    lua_pushcclosure(L, removed_field, 1);
    lua_setfield(L, -2, "__newindex");
    lua_pushstring(L, r->name);
    lua_pushcclosure(L, removed_call, 1);
    lua_setfield(L, -2, "__call");
    lua_setmetatable(L, -2);
    lua_setfield(L, -2, r->name);
  }
  lua_pushglobaltable(L);
  lua_newtable(L);
  lua_pushvalue(L, -3);
  lua_pushcclosure(L, surface_missing, 1);
  lua_setfield(L, -2, "__index");
  lua_setmetatable(L, -2);
  lua_pop(L, 2);

  install_load(L);

  return L;
}
