#include "store.h"

#include <stdio.h>
#include <string.h>

#include "lauxlib.h"

#define STORE_LIST "cosmic.store.databases"

/* Reads one module's bytecode out of one database. Returns 1 with the
 * chunk on the stack, 0 when that database does not hold it, and -1 with
 * a message on the stack when the read itself failed. */
static int load_from(lua_State *L, sqlite3 *db, const char *name) {
  static const char *query = "SELECT bytecode FROM modules WHERE path = ?1";
  sqlite3_stmt *stmt = NULL;
  if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) != SQLITE_OK) {
    lua_pushstring(L, sqlite3_errmsg(db));
    return -1;
  }
  sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);

  int rc = sqlite3_step(stmt);
  if (rc == SQLITE_DONE) {
    sqlite3_finalize(stmt);
    return 0;
  }
  if (rc != SQLITE_ROW) {
    lua_pushstring(L, sqlite3_errmsg(db));
    sqlite3_finalize(stmt);
    return -1;
  }

  const void *bytes = sqlite3_column_blob(stmt, 0);
  int len = sqlite3_column_bytes(stmt, 0);
  char chunk[256];
  snprintf(chunk, sizeof chunk, "@%s", name);
  int loaded = luaL_loadbufferx(L, bytes, (size_t)len, chunk, "b");
  sqlite3_finalize(stmt);
  if (loaded != LUA_OK) {
    return -1;
  }
  return 1;
}

static sqlite3 *database_at(lua_State *L, int list, lua_Integer index) {
  lua_geti(L, list, index);
  sqlite3 *db = lua_touserdata(L, -1);
  lua_pop(L, 1);
  return db;
}

/* The one searcher. Its upvalue is the list of databases, in the order
 * they are searched. */
static int store_searcher(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);

  for (lua_Integer i = 1; i <= count; i++) {
    sqlite3 *db = database_at(L, list, i);
    if (db == NULL) {
      continue;
    }
    int found = load_from(L, db, name);
    if (found == 1) {
      lua_pushstring(L, name);
      return 2;
    }
    if (found < 0) {
      return lua_error(L);
    }
  }

  lua_pushfstring(L, "\n\tno module '%s' in the store", name);
  return 1;
}

/* Opens another database and searches it ahead of every other, which is
 * what a project's own build database needs. */
static int store_attach(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  sqlite3 *db = NULL;
  int rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                           NULL);
  if (rc != SQLITE_OK) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, db == NULL ? sqlite3_errstr(rc) : sqlite3_errmsg(db));
    sqlite3_close_v2(db);
    return 2;
  }

  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  for (lua_Integer i = count; i >= 1; i--) {
    lua_geti(L, list, i);
    lua_seti(L, list, i + 1);
  }
  lua_pushlightuserdata(L, db);
  lua_seti(L, list, 1);

  lua_pushboolean(L, 1);
  return 1;
}

/* One module's compiled bytes, for a caller that must load a chunk in
 * an environment of its own -- which is how the vendored compiler runs
 * without the names the surface removed. */
static int store_bytecode(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);

  static const char *query = "SELECT bytecode FROM modules WHERE path = ?1";
  for (lua_Integer i = 1; i <= count; i++) {
    sqlite3 *db = database_at(L, list, i);
    if (db == NULL) {
      continue;
    }
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) != SQLITE_OK) {
      continue;
    }
    sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
      lua_pushlstring(L, sqlite3_column_blob(stmt, 0),
                      (size_t)sqlite3_column_bytes(stmt, 0));
      sqlite3_finalize(stmt);
      return 1;
    }
    sqlite3_finalize(stmt);
  }
  lua_pushnil(L);
  lua_pushfstring(L, "no module '%s' in the store", name);
  return 2;
}

/* One entry of the meta table, which is where the build records what it
 * decided: the entry module's name, the hash of the tool. */
static int store_meta(lua_State *L) {
  const char *key = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);

  static const char *query = "SELECT value FROM meta WHERE key = ?1";
  for (lua_Integer i = 1; i <= count; i++) {
    sqlite3 *db = database_at(L, list, i);
    if (db == NULL) {
      continue;
    }
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) != SQLITE_OK) {
      continue;
    }
    sqlite3_bind_text(stmt, 1, key, -1, SQLITE_STATIC);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
      lua_pushlstring(L, (const char *)sqlite3_column_text(stmt, 0),
                      (size_t)sqlite3_column_bytes(stmt, 0));
      sqlite3_finalize(stmt);
      return 1;
    }
    sqlite3_finalize(stmt);
  }
  lua_pushnil(L);
  return 1;
}

static int open_store_module(lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, STORE_LIST);
  lua_newtable(L);
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, store_attach, 1);
  lua_setfield(L, -2, "attach");
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, store_bytecode, 1);
  lua_setfield(L, -2, "bytecode");
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, store_meta, 1);
  lua_setfield(L, -2, "meta");
  lua_remove(L, -2);
  return 1;
}

int cosmic_store_install(lua_State *L, sqlite3 *binary) {
  lua_newtable(L);
  if (binary != NULL) {
    lua_pushlightuserdata(L, binary);
    lua_seti(L, -2, 1);
  }
  lua_pushvalue(L, -1);
  lua_setfield(L, LUA_REGISTRYINDEX, STORE_LIST);

  /* package.searchers keeps the preload searcher and gains ours; the
   * two that read the filesystem go away with package.path. */
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "searchers");
  lua_pushvalue(L, -3);
  lua_pushcclosure(L, store_searcher, 1);
  lua_seti(L, -2, 2);
  for (lua_Integer i = (lua_Integer)lua_rawlen(L, -1); i > 2; i--) {
    lua_pushnil(L);
    lua_seti(L, -2, i);
  }
  lua_pop(L, 2);

  lua_getfield(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, open_store_module);
  lua_setfield(L, -2, "cosmic.store");
  lua_pop(L, 2);
  return 0;
}

const char *cosmic_store_meta(lua_State *L, const char *key) {
  lua_getfield(L, LUA_REGISTRYINDEX, STORE_LIST);
  lua_pushcclosure(L, store_meta, 1);
  lua_pushstring(L, key);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    lua_pop(L, 1);
    return NULL;
  }
  const char *value = lua_tostring(L, -1);
  lua_pop(L, 1);
  return value;
}
