/* The test instruments of every core but the checked one: none. */

#include "testing.h"

int cosmic_open_testing(lua_State *L) {
  lua_createtable(L, 0, 1);
  lua_pushliteral(L, COSMIC_CONFIGURATION_NAME);
  lua_setfield(L, -2, "configuration");
  return 1;
}
