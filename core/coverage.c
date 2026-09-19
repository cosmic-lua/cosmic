#include "coverage.h"

#include "lauxlib.h"

/* Where the current collection's hits live between one `start` and its
 * matching `stop`: {short_src: {line: true}}. `start` always replaces
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
 * the C API: hits[ar->short_src][ar->currentline] = true, creating the
 * per-file table the first time a given file is seen. */
static void native_line_hook(lua_State *L, lua_Debug *ar) {
  lua_getinfo(L, "Sl", ar);

  lua_getfield(L, LUA_REGISTRYINDEX, COVERAGE_HITS); /* hits */
  lua_getfield(L, -1, ar->short_src);                /* hits, hits[src]? */
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_setfield(L, -3, ar->short_src); /* hits[src] = new table */
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

void cosmic_coverage_install(lua_State *L) {
  lua_newtable(L);
  lua_pushcfunction(L, coverage_start);
  lua_setfield(L, -2, "start");
  lua_pushcfunction(L, coverage_stop);
  lua_setfield(L, -2, "stop");
}
