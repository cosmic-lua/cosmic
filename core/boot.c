#include "boot.h"

#include <stdio.h>
#include <string.h>

#include "bridge.lua.h"
#include "lauxlib.h"

static int report(lua_State *L, const char *what) {
  const char *message = lua_tostring(L, -1);
  fprintf(stderr, "cosmic boot: %s: %s\n", what,
          message == NULL ? "no message" : message);
  return 1;
}

/* Runs the bridge chunk and leaves its table on the stack. */
static int run_bridge(lua_State *L, const char *root) {
  if (luaL_loadbufferx(L, cosmic_bridge_source, strlen(cosmic_bridge_source),
                       "@cosmic:bridge", "t") != LUA_OK) {
    return report(L, "the bridge would not compile");
  }
  lua_pushstring(L, root);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return report(L, "the bridge would not run");
  }
  return 0;
}

/* Loads the vendored compiler under the environment the bridge built. */
static int run_compiler(lua_State *L, const char *tl_dir, int bridge) {
  char path[4096];
  snprintf(path, sizeof path, "%s/tl.lua", tl_dir);
  if (luaL_loadfilex(L, path, "t") != LUA_OK) {
    return report(L, "the compiler would not load");
  }
  lua_getfield(L, bridge, "environment");
  if (lua_setupvalue(L, -2, 1) == NULL) {
    fprintf(stderr, "cosmic boot: the compiler has no environment to set\n");
    return 1;
  }
  if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
    return report(L, "the compiler would not run");
  }
  return 0;
}

int cosmic_boot(lua_State *L, const char *root, const char *tl_dir, int argc,
                char **argv) {
  if (run_bridge(L, root) != 0) {
    return 1;
  }
  int bridge = lua_gettop(L);

  if (run_compiler(L, tl_dir, bridge) != 0) {
    return 1;
  }
  int compiler = lua_gettop(L);

  /* The compiler is a module like any other from here on. */
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
  lua_pushvalue(L, compiler);
  lua_setfield(L, -2, "tl");
  lua_pop(L, 1);

  lua_getfield(L, bridge, "searcher_for");
  lua_pushvalue(L, compiler);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return report(L, "the searcher would not be made");
  }

  lua_getglobal(L, "package");
  lua_getfield(L, -1, "searchers");
  lua_pushvalue(L, -3);
  lua_seti(L, -2, 2);
  lua_pop(L, 3);

  lua_getglobal(L, "require");
  lua_pushstring(L, "build.boot");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return report(L, "build.boot would not load");
  }
  if (!lua_isfunction(L, -1)) {
    fprintf(stderr, "cosmic boot: build.boot is not a function\n");
    return 1;
  }

  lua_pushstring(L, root);
  lua_newtable(L);
  for (int i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_seti(L, -2, i + 1);
  }
  if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
    return report(L, "build.boot failed");
  }
  return (int)luaL_optinteger(L, -1, 0);
}
