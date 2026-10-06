#include "assertions.h"

#include "lauxlib.h"

/* The registry slot (by address) of the calls counted so far. */
static char count_key;

static lua_Integer calls (lua_State *L) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &count_key);
  lua_Integer n = lua_tointeger(L, -1);
  lua_pop(L, 1);
  return n;
}

static void set_calls (lua_State *L, lua_Integer n) {
  lua_pushinteger(L, n);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &count_key);
}

/* Lua's own `assert` (lbaselib.c's luaB_assert), counting the call first.
 * A failure raises as `error(message, 1)` does from `assert`'s own frame,
 * so a string message gains the position of the function that called it. */
static int counting_assert (lua_State *L) {
  set_calls(L, calls(L) + 1);
  if (lua_toboolean(L, 1)) return lua_gettop(L);
  luaL_checkany(L, 1);
  lua_remove(L, 1);
  lua_pushliteral(L, "assertion failed!");
  lua_settop(L, 1);
  if (lua_type(L, 1) == LUA_TSTRING) {
    luaL_where(L, 1);
    lua_pushvalue(L, 1);
    lua_concat(L, 2);
  }
  return lua_error(L);
}

static int assertions_count (lua_State *L) {
  lua_pushinteger(L, calls(L));
  return 1;
}

static int assertions_reset (lua_State *L) {
  set_calls(L, 0);
  return 0;
}

int cosmic_open_assertions (lua_State *L) {
  lua_createtable(L, 0, 3);
  lua_pushcfunction(L, counting_assert);
  lua_setfield(L, -2, "assert");
  lua_pushcfunction(L, assertions_count);
  lua_setfield(L, -2, "count");
  lua_pushcfunction(L, assertions_reset);
  lua_setfield(L, -2, "reset");
  return 1;
}
