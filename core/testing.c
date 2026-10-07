/*
 * The test instruments of every core but the checked one: the same
 * names, so the table cosmic/internal/testing.d.tl declares is the one
 * every core registers, but each instrument raises rather than
 * instrument. No shipped core has an allocator a program can make
 * fail. The five raw namespace calls (core/namespace_calls.c) are no
 * instruments: they are real here, as in the checked core, and not
 * stand-ins.
 */

#include "testing.h"

#include "lauxlib.h"
#include "namespace_calls.h"

/* The instruments core/testing_checked.c registers, by name: edit the
 * two lists together. core/declarations_test.tl fails the run of
 * whichever core misses one cosmic/internal/testing.d.tl declares. */
static const char *const instruments[] = {
  "fail_allocations", "allow_allocations", "open_statements", "open_descriptors", "socket_sigpipe", "socket_send_rights",
  "c_heap",           "fail_at",           "live_transfers",
  "executable_path",  "mountinfo_local_flock", NULL,
};

/* Stands in for the instrument its upvalue names, which only the
 * checked core carries: raises, whatever it is given. */
static int checked_only (lua_State *L) {
  return luaL_error(L, "%s: only the checked core has test instruments",
                    lua_tostring(L, lua_upvalueindex(1)));
}

int cosmic_open_testing (lua_State *L) {
  lua_createtable(L, 0, 16); /* the stand-ins, the namespace calls, "configuration" */
  for (const char *const *name = instruments; *name != NULL; name++) {
    lua_pushstring(L, *name);
    lua_pushcclosure(L, checked_only, 1);
    lua_setfield(L, -2, *name);
  }
  cosmic_add_namespace_calls(L);
  lua_pushliteral(L, COSMIC_CONFIGURATION_NAME);
  lua_setfield(L, -2, "configuration");
  return 1;
}
