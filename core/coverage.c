#include "coverage.h"

#include "lauxlib.h"

/* Where the current collection's hits live between one `start` and its
 * matching `stop`: {source: {line: true}}. `start` always replaces
 * this with a fresh, empty table, so a `stop` with no matching `start`
 * reads whatever the last `start` put here (or nothing at all, before
 * any `start` ever ran) rather than crashing -- the Lua-side session
 * token (cosmic/coverage.tl) is what actually keeps every `start`
 * paired with exactly one `stop`; this registry slot does not need to
 * enforce that itself, and does not clear itself on `stop`. */
#define COVERAGE_HITS "cosmic.coverage.native.hits"

/* Fires on every line executed while the hook is installed. `ar` is
 * only valid for the duration of this call.
 *
 * "S" and "l" are the two `lua_getinfo` selectors that fill in fields
 * of `ar` itself and push nothing onto the stack -- unlike asking Lua
 * code to call `debug.getinfo`, answering "what file, what line" here
 * costs no table or string allocation beyond the one line this hook
 * itself records. Everything after that is plain table writes through
 * the C API: hits[source][ar->currentline] = true, creating the
 * per-file table the first time a given file is seen. */
static void native_line_hook(lua_State *L, lua_Debug *ar) {
  lua_getinfo(L, "Sl", ar);

  /* short_src is a truncated display label, not a module identity.
   * File chunks use @module; strip only that marker to match store keys. */
  const char *source = ar->source;
  size_t length = ar->srclen;
  if (length > 0 && source[0] == '@') {
    source++;
    length--;
  }
  lua_getfield(L, LUA_REGISTRYINDEX, COVERAGE_HITS); /* hits */
  lua_pushlstring(L, source, length);
  lua_gettable(L, -2); /* hits, hits[src]? */
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushlstring(L, source, length);
    lua_pushvalue(L, -2);
    lua_settable(L, -4); /* hits[src] = new table */
  }
  lua_pushboolean(L, 1);
  lua_seti(L, -2, ar->currentline); /* hits[src][line] = true */
  lua_pop(L, 2);                    /* the per-file table, and hits */
}

/* Begins a fresh collection: a new, empty hits table, and the line
 * hook installed. Takes no argument and returns nothing; a caller
 * already holding an open collection that starts another loses no
 * data of its own -- cosmic/coverage.tl's session token is what keeps
 * that from happening in practice. */
static int coverage_start(lua_State *L) {
  lua_newtable(L);
  lua_setfield(L, LUA_REGISTRYINDEX, COVERAGE_HITS);
  lua_sethook(L, native_line_hook, LUA_MASKLINE, 0);
  return 0;
}

/* Removes the line hook and returns everything collected since the
 * matching `start`, or an empty table when `stop` runs with no `start`
 * to match. */
static int coverage_stop(lua_State *L) {
  lua_sethook(L, NULL, 0, 0);
  lua_getfield(L, LUA_REGISTRYINDEX, COVERAGE_HITS);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
  }
  return 1;
}

/* A read of the current collection while it keeps running: unlike
 * `stop`, this touches neither the hook nor the registry slot the hook
 * keeps writing to. What it returns is a copy, all the way down -- a
 * fresh top-level table and a fresh copy of each per-file table -- so
 * a caller can read or even mutate what it got back without either
 * racing the hook's own writes into the live table or corrupting the
 * collection this same caller, or any other, is still relying on.
 * Nil (no `start` has ever run) reads as an empty table, same as
 * `stop`. */
static int coverage_snapshot(lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, COVERAGE_HITS);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    return 1;
  }
  int live = lua_gettop(L); /* the live hits table the hook still writes */

  lua_newtable(L);
  int copy = lua_gettop(L); /* what this function returns */

  lua_pushnil(L);
  while (lua_next(L, live) != 0) {
    /* live copy src per_file */
    int per_file = lua_gettop(L);
    int src = per_file - 1;

    lua_newtable(L);
    int per_copy = lua_gettop(L);

    lua_pushnil(L);
    while (lua_next(L, per_file) != 0) {
      /* ... line true */
      lua_pushvalue(L, -2); /* ... line true line */
      lua_pushvalue(L, -2); /* ... line true line true */
      lua_settable(L, per_copy);
      lua_pop(L, 1); /* drop the value; the key stays for the next lua_next */
    }

    lua_pushvalue(L, src);      /* live copy src per_file per_copy src */
    lua_pushvalue(L, per_copy); /* ... src per_copy */
    lua_settable(L, copy);      /* copy[src] = per_copy */
    lua_pop(L, 2);              /* per_copy and per_file; src stays as the key */
  }
  return 1;
}

void cosmic_coverage_install(lua_State *L) {
  lua_newtable(L);
  lua_pushcfunction(L, coverage_start);
  lua_setfield(L, -2, "start");
  lua_pushcfunction(L, coverage_stop);
  lua_setfield(L, -2, "stop");
  lua_pushcfunction(L, coverage_snapshot);
  lua_setfield(L, -2, "snapshot");
}
