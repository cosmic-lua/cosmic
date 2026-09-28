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

static inline int cosmic_checkint (lua_State *L, int arg) {
  lua_Integer value = luaL_checkinteger(L, arg);
  luaL_argcheck(L, value >= INT_MIN && value <= INT_MAX, arg,
                "does not fit in an int");
  return (int)value;
}

static inline int cosmic_optint (lua_State *L, int arg, int otherwise) {
  return lua_isnoneornil(L, arg) ? otherwise : cosmic_checkint(L, arg);
}

/* A descriptor argument: `cosmic_checkint`'s, refused -- raised, naming
 * the argument -- where it is the descriptor a portable start retains on
 * the artifact (core/store.h's `cosmic_store_artifact`), through which
 * core/vfs.c reads the embedded database. No binding answers it but
 * `relaunch`, for `spawn` to hand on to this same program, so a caller
 * that passes it anywhere else has a number no correct program uses:
 * with it, a test would read every module the program carries, past
 * build/test_worker.tl's hold on the store and past every key. Every
 * binding that takes a descriptor takes it through one of these
 * (build/c/rules.tl's "descriptor-argument"): `cosmic_checkfd` for an
 * argument, `cosmic_argfd` for one read out of argument `arg`'s table
 * or checked otherwise. Defined in core/store.c, which holds the
 * artifact. */
int cosmic_checkfd (lua_State *L, int arg);
void cosmic_argfd (lua_State *L, int arg, lua_Integer fd);

/* The exit status a main function left at `index`: nothing is 0, and a
 * whole number from 0 to 255, or text naming one (lua_tointegerx's
 * reading), is itself. Anything else is -1, for the caller to
 * refuse: an exit keeps only the low byte, so 256 would pass for success,
 * and the value is read outside any protected call, where a raise ends
 * the process in a panic. */
static inline int cosmic_tostatus (lua_State *L, int index) {
  if (lua_isnoneornil(L, index)) return 0;
  int exact = 0;
  lua_Integer status = lua_tointegerx(L, index, &exact);
  if (!exact || status < 0 || status > 255) return -1;
  return (int)status;
}

#endif
