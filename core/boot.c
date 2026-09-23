#include "boot.h"

#include <stdio.h>
#include <string.h>

#include "bridge.lua.h"
#include "check.h"
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

/* Reads a whole file into a Lua string on the stack. */
static int slurp(lua_State *L, const char *path) {
  FILE *f = fopen(path, "rb");
  if (f == NULL) {
    fprintf(stderr, "cosmic boot: cannot read %s\n", path);
    return 1;
  }
  luaL_Buffer buffer;
  luaL_buffinit(L, &buffer);
  /* A short read is the end of the file or an error, and only ferror
   * says which: a read error must not pass for a shorter file. */
  for (;;) {
    char room[1 << 16];
    size_t got = fread(room, 1, sizeof room, f);
    luaL_addlstring(&buffer, room, got);
    if (got < sizeof room) {
      break;
    }
  }
  int failed = ferror(f);
  fclose(f);
  luaL_pushresult(&buffer);
  if (failed) {
    lua_pop(L, 1);
    fprintf(stderr, "cosmic boot: cannot read %s\n", path);
    return 1;
  }
  return 0;
}

/* The syscall table's declaration has to exist before any module that
 * requires it is compiled, so the generator runs first and on its own.
 * It imports nothing, which is what makes that possible. The result is
 * handed to the bridge, which serves it to the checker from memory;
 * nothing is written to disk. */
static int declare_syscalls(lua_State *L, const char *root, int bridge) {
  char path[4096];

  lua_getglobal(L, "require");
  lua_pushstring(L, "build.gen_syscalls");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return report(L, "build.gen_syscalls would not load");
  }
  lua_getfield(L, -1, "declaration");

  snprintf(path, sizeof path, "%s/core/syscalls.h", root);
  if (slurp(L, path) != 0) {
    return 1;
  }
  if (lua_pcall(L, 1, 2, 0) != LUA_OK) {
    return report(L, "the declaration would not be made");
  }
  if (lua_isnil(L, -2)) {
    fprintf(stderr, "cosmic boot: core/syscalls.h: %s\n",
            lua_tostring(L, -1));
    return 1;
  }

  lua_getfield(L, bridge, "declare");
  lua_pushstring(L, "cosmic.sys");
  lua_pushvalue(L, -4);
  if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
    return report(L, "the declaration would not be declared");
  }
  lua_pop(L, 3);
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

  /* The compiler answers to the name its declaration carries, so the
   * tree requires it like any other module. */
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
  lua_pushvalue(L, compiler);
  lua_setfield(L, -2, "build.compiler");
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

  if (declare_syscalls(L, root, bridge) != 0) {
    return 1;
  }

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
    lua_seti(L, -2, i);
  }
  if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
    return report(L, "build.boot failed");
  }
  int status = cosmic_tostatus(L, -1);
  if (status < 0) {
    fprintf(stderr, "cosmic boot: build.boot returned no exit status\n");
    return 1;
  }
  return status;
}
