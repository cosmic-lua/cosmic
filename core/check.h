/*
 * Argument checks the bindings share, in the manner of lauxlib's own:
 * an argument no correct program passes raises, naming the argument,
 * rather than being cast into something else. A Lua integer is 64 bits
 * and most of what it is handed to in C is an int; a value that does
 * not fit is refused, never truncated -- descriptor 2^32 + 2 is not 2.
 */

#ifndef COSMIC_CHECK_H
#define COSMIC_CHECK_H

#include <limits.h>

#include "lauxlib.h"
#include "lua.h"

static inline int cosmic_checkint(lua_State *L, int arg) {
  lua_Integer value = luaL_checkinteger(L, arg);
  luaL_argcheck(L, value >= INT_MIN && value <= INT_MAX, arg,
                "does not fit in an int");
  return (int)value;
}

static inline int cosmic_optint(lua_State *L, int arg, int otherwise) {
  return lua_isnoneornil(L, arg) ? otherwise : cosmic_checkint(L, arg);
}

#endif
