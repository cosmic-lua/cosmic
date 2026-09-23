/*
 * A resource held across calls that can raise. Any Lua call that
 * allocates can raise on memory, and a raise unwinds straight past the C
 * that would have released a DIR or a statement held in a local. A guard
 * is a to-be-closed userdata pushed before the resource is acquired:
 * Lua closes it when the function returns, when anything raises, or when
 * its slot is popped, and closing it releases whatever it holds. It is
 * how lauxlib keeps its own buffer box from leaking.
 *
 *   struct cosmic_guard *g = cosmic_guard_push(L, release);
 *   g->resource = acquire();          -- after the push, never before
 *   ... anything that may raise ...
 *   cosmic_guard_release(g);          -- optional: release it early
 *
 * The slot is marked to-be-closed, so it may only leave the stack by a
 * return, a raise, lua_pop or lua_settop: push the guard below what the
 * function returns.
 */

#ifndef COSMIC_GUARD_H
#define COSMIC_GUARD_H

#include "lauxlib.h"
#include "lua.h"

#define COSMIC_GUARD_TYPE "cosmic.guard"

struct cosmic_guard {
  void (*release)(void *resource);
  void *resource;
};

/* Releases what the guard holds, once; a guard holding nothing is left
 * alone, so an early release and the close that follows it compose. */
static inline void cosmic_guard_release(struct cosmic_guard *guard) {
  void *resource = guard->resource;
  if (resource != NULL) {
    guard->resource = NULL;
    guard->release(resource);
  }
}

static inline int cosmic_guard_close(lua_State *L) {
  cosmic_guard_release(lua_touserdata(L, 1));
  return 0;
}

/* Pushes an empty guard that releases with `release`, and marks its slot
 * to-be-closed. The push itself may raise; nothing is held yet if so. */
static inline struct cosmic_guard *cosmic_guard_push(
    lua_State *L, void (*release)(void *resource)) {
  struct cosmic_guard *guard = lua_newuserdatauv(L, sizeof *guard, 0);
  guard->release = release;
  guard->resource = NULL;
  if (luaL_newmetatable(L, COSMIC_GUARD_TYPE)) {
    lua_pushcfunction(L, cosmic_guard_close);
    lua_setfield(L, -2, "__close");
    lua_pushcfunction(L, cosmic_guard_close);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  lua_toclose(L, -1);
  return guard;
}

#endif
