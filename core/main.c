/*
 * The entry. It finds the database attached to the running executable,
 * opens it through the offset VFS, and hands control to the `main`
 * module inside it. With no database attached it can bridge into Teal
 * from the tree instead, which is how the first binary gets built.
 */

#include <stdio.h>
#include <string.h>

#include "boot.h"
#include "lauxlib.h"
#include "locate.h"
#include "sqlite.h"
#include "sqlite3.h"
#include "store.h"
#include "surface.h"
#include "vfs.h"

static int complain(const char *what, const char *detail) {
  if (detail == NULL) {
    fprintf(stderr, "cosmic: %s\n", what);
  } else {
    fprintf(stderr, "cosmic: %s: %s\n", what, detail);
  }
  return 2;
}

static sqlite3 *open_attached(const char *path,
                              const struct cosmic_attachment *at) {
  if (cosmic_vfs_register() != SQLITE_OK) {
    return NULL;
  }
  char uri[8192];
  if (!cosmic_vfs_uri(uri, sizeof uri, path, at->offset, at->length)) {
    return NULL;
  }
  sqlite3 *db = NULL;
  int rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                           COSMIC_VFS_NAME);
  if (rc != SQLITE_OK) {
    sqlite3_close_v2(db);
    return NULL;
  }
  return db;
}

/* Runs the `main` module with the command line as a table. */
static int run_main(lua_State *L, int argc, char **argv) {
  if (!cosmic_store_load(L, "main")) {
    return complain("the database holds no entry", lua_tostring(L, -1));
  }
  lua_newtable(L);
  for (int i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_seti(L, -2, i);
  }
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    const char *message = lua_tostring(L, -1);
    fprintf(stderr, "cosmic: %s\n", message == NULL ? "failed" : message);
    return 1;
  }
  return (int)luaL_optinteger(L, -1, 0);
}

int main(int argc, char **argv) {
  sqlite3_initialize();

  char self[4096];
  if (!cosmic_executable_path(self, sizeof self)) {
    return complain("cannot find my own path", NULL);
  }

  struct cosmic_attachment attached;
  int found = cosmic_locate(self, &attached);
  if (found < 0) {
    return complain("cannot read my own file", self);
  }

  lua_State *L = cosmic_surface_open();
  if (L == NULL) {
    return complain("no memory for a Lua state", NULL);
  }
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, cosmic_open_sqlite);
  lua_setfield(L, -2, "cosmic.sqlite");
  lua_pop(L, 1);

  if (found == 0) {
    /* No database: the tree is the only source, so this is a build
     * machine bridging into Teal. A shipped binary never gets here. */
    if (argc >= 4 && strcmp(argv[1], "--boot") == 0) {
      int status = cosmic_boot(L, argv[2], argv[3], argc, argv);
      lua_close(L);
      return status;
    }
    lua_close(L);
    return complain("no database attached, and no tree to boot from", self);
  }

  sqlite3 *db = open_attached(self, &attached);
  if (db == NULL) {
    lua_close(L);
    return complain("cannot open my own database", self);
  }
  cosmic_store_install(L, db);

  int status = run_main(L, argc, argv);
  lua_close(L);
  sqlite3_close_v2(db);
  return status;
}
