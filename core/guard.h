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
 *
 * Closing calls the guard's __close, and a call can itself need memory.
 * When memory is so short that even that call cannot be made, Lua drops
 * the close; the guard's __gc then releases the resource when the guard
 * is collected -- the same backstop lauxlib's buffer box has. So what a
 * guard holds is released at once, or at the latest by the collector.
 *
 * A guard cannot hand a resource on to what its function returns: the
 * close at the return is a call, and a call that memory refuses raises
 * after the hand-off, taking the returned values with it. A resource the
 * caller is to own is acquired after everything that allocates instead.
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
 * to-be-closed. The push itself may raise; nothing is held yet if so.
 * The metatable is registered only once it is whole: registered first
 * (as luaL_newmetatable does) and then raised out of while it was being
 * filled, it would stay in the registry without __close or __gc, and
 * every guard after it would release nothing. */
static inline struct cosmic_guard *cosmic_guard_push(
    lua_State *L, void (*release)(void *resource)) {
  struct cosmic_guard *guard = lua_newuserdatauv(L, sizeof *guard, 0);
  guard->release = release;
  guard->resource = NULL;
  if (luaL_getmetatable(L, COSMIC_GUARD_TYPE) == LUA_TNIL) {
    lua_pop(L, 1);
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, cosmic_guard_close);
    lua_setfield(L, -2, "__close");
    lua_pushcfunction(L, cosmic_guard_close);
    lua_setfield(L, -2, "__gc");
    lua_pushvalue(L, -1);
    lua_setfield(L, LUA_REGISTRYINDEX, COSMIC_GUARD_TYPE);
  }
  lua_setmetatable(L, -2);
  lua_toclose(L, -1);
  return guard;
}

#endif
