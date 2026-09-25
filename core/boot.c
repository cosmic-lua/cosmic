#include "boot.h"

#include <stdbool.h>
#include <stdio.h>

#include "check.h"
#include "lauxlib.h"

static int report (lua_State *L, const char *what) {
  const char *message = lua_tostring(L, -1);
  fprintf(stderr, "cosmic boot: %s: %s\n", what,
          message == NULL ? "no message" : message);
  return 1;
}

/* Writes `dir`/`name` into `path`, which holds `size` bytes, saying so
 * when it does not fit. */
static bool join_path (char *path, size_t size, const char *dir,
                       const char *name) {
  int written = snprintf(path, size, "%s/%s", dir, name);
  if (written < 0 || (size_t)written >= size) {
    fprintf(stderr, "cosmic boot: %s/%s is too long a path\n", dir, name);
    return false;
  }
  return true;
}

/* Runs the tree's bridge chunk, core/bridge.lua, and leaves its table
 * on the stack. */
static int run_bridge (lua_State *L, const char *root) {
  char path[4096];
  if (!join_path(path, sizeof path, root, "core/bridge.lua")) {
    return 1;
  }
  if (luaL_loadfilex(L, path, "t") != LUA_OK) {
    return report(L, "the bridge would not load");
  }
  lua_pushstring(L, root);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return report(L, "the bridge would not run");
  }
  return 0;
}

/* Loads the vendored compiler under the environment the bridge built,
 * then has it compile the compiler's patched Teal source (the bridge's
 * `bootstrap`): leaves that compiler, and the Lua it was compiled to,
 * on the stack. */
static int run_compiler (lua_State *L, const char *tl_dir, int bridge) {
  char path[4096];
  if (!join_path(path, sizeof path, tl_dir, "tl.lua")) {
    return 1;
  }
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
  lua_getfield(L, bridge, "bootstrap");
  lua_insert(L, -2);
  lua_pushstring(L, tl_dir);
  if (lua_pcall(L, 2, 2, 0) != LUA_OK) {
    return report(L, "the compiler would not compile itself");
  }
  return 0;
}

/* Reads a whole file into a Lua string on the stack. */
static int slurp (lua_State *L, const char *path) {
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

/* The declarations derived from a header -- the syscall table's and
 * the raw process table's, each of `build.gen_syscalls`' targets -- have
 * to exist before any module that requires one is compiled, so the
 * generator runs first and on its own. It imports nothing, which is
 * what makes that possible. Each result is handed to the bridge, which
 * serves it to the checker from memory; nothing is written to disk. */
static int declare_syscalls (lua_State *L, const char *root, int bridge) {
  char path[4096];

  lua_getglobal(L, "require");
  lua_pushstring(L, "build.gen_syscalls");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return report(L, "build.gen_syscalls would not load");
  }
  int generator = lua_gettop(L);
  lua_getfield(L, generator, "targets");
  int targets = lua_gettop(L);
  if (!lua_istable(L, targets)) {
    fprintf(stderr, "cosmic boot: build.gen_syscalls names no targets\n");
    return 1;
  }
  lua_Integer count = (lua_Integer)lua_rawlen(L, targets);
  for (lua_Integer i = 1; i <= count; i++) {
    lua_rawgeti(L, targets, i);
    int derivation = lua_gettop(L);
    if (!lua_istable(L, derivation)) {
      fprintf(stderr, "cosmic boot: build.gen_syscalls target %lld is not a table\n",
              (long long)i);
      return 1;
    }
    lua_getfield(L, derivation, "target");
    int target = lua_gettop(L);
    const char *header = NULL;
    if (lua_istable(L, target)) {
      lua_getfield(L, target, "header");
      header = lua_tostring(L, -1);
    }
    if (header == NULL) {
      fprintf(stderr, "cosmic boot: build.gen_syscalls target %lld names no header\n",
              (long long)i);
      return 1;
    }
    if (!join_path(path, sizeof path, root, header)) {
      return 1;
    }

    lua_getfield(L, generator, "declaration");
    if (slurp(L, path) != 0) {
      return 1;
    }
    lua_pushvalue(L, target);
    if (lua_pcall(L, 2, 2, 0) != LUA_OK) {
      return report(L, "the declaration would not be made");
    }
    if (lua_isnil(L, -2)) {
      fprintf(stderr, "cosmic boot: %s: %s\n", header, lua_tostring(L, -1));
      return 1;
    }

    lua_getfield(L, bridge, "declare");
    lua_getfield(L, derivation, "path");
    lua_pushvalue(L, -4);
    if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
      return report(L, "the declaration would not be declared");
    }
    lua_settop(L, derivation - 1);
  }
  lua_settop(L, generator - 1);
  return 0;
}

int cosmic_boot (lua_State *L, const char *root, const char *tl_dir, int argc,
                 char **argv) {
  if (run_bridge(L, root) != 0) {
    return 1;
  }
  int bridge = lua_gettop(L);

  if (run_compiler(L, tl_dir, bridge) != 0) {
    return 1;
  }
  int source = lua_gettop(L);
  int compiler = source - 1;

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
  lua_pushvalue(L, source);
  if (lua_pcall(L, 3, 1, 0) != LUA_OK) {
    return report(L, "build.boot failed");
  }
  int status = cosmic_tostatus(L, -1);
  if (status < 0) {
    fprintf(stderr, "cosmic boot: build.boot returned no exit status\n");
    return 1;
  }
  return status;
}
