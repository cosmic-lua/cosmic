/*
 * The two failure shapes every binding in the syscall table returns.
 * A value that failed is `nil, error, errno`; an effect that failed is
 * `false, error, errno`. Nothing else shares a slot.
 */

#ifndef COSMIC_FAIL_H
#define COSMIC_FAIL_H

#include <errno.h>
#include <string.h>

#include "lua.h"

static inline int cosmic_fail(lua_State *L, int number) {
  lua_pushnil(L);
  lua_pushstring(L, strerror(number));
  lua_pushinteger(L, number);
  return 3;
}

static inline int cosmic_fail_effect(lua_State *L, int number) {
  lua_pushboolean(L, 0);
  lua_pushstring(L, strerror(number));
  lua_pushinteger(L, number);
  return 3;
}

static inline int cosmic_ok(lua_State *L) {
  lua_pushboolean(L, 1);
  return 1;
}

#endif
