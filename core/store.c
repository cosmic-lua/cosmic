#include "store.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"

#define STORE_LIST "cosmic.store.databases"

/* A prepare or a step that fails for a reason other than "no such row"
 * means the attached database itself cannot be trusted -- truncated,
 * corrupted, or not a database at all past whatever let `locate` find
 * it. There is no caller to hand that to: the process exits. */
static void die_unreadable(sqlite3 *db) {
  fprintf(stderr, "cosmic: the attached database is unreadable: %s\n",
          sqlite3_errmsg(db));
  exit(2); /* exits: a database this broken has no well-formed answer to
              return, honest or otherwise */
}

/* Where the raw `cosmic.internal.store`, `cosmic.internal.sqlite`, and
 * `cosmic.internal.debug` values live: never in package.preload and
 * never a name `require` resolves on its own, so nothing a project's
 * own code can `require` reaches them. `require` caches whatever a
 * loader returns under the name it was asked for, so a value that must
 * be re-checked on every access can never be that cached value --
 * `cosmic.store`, `cosmic.sqlite`, and `cosmic.coverage` (the wrappers,
 * one per raw module) get theirs handed straight to their own loader
 * instead, as the `extra` argument `require` passes it. calling the
 * searcher by hand yields the same value, and that is no escalation:
 * the raw table holds nothing the wrapper does not already hand out. */
#define RAW_TABLE "cosmic.store.raw"

/* True when `name` is a path the binary's own tree owns and the kind is
 * one a running program actually executes -- what earns a module the
 * raw value behind its wrapper, handed at the moment it is loaded. */
static int names_trusted_kind(const char *name, const char *kind) {
  int reserved = strncmp(name, "cosmic.", 7) == 0;
  int runnable = kind != NULL &&
                (strcmp(kind, "module") == 0 || strcmp(kind, "main") == 0);
  return reserved && runnable;
}

/* The raw `cosmic.internal.store`, `cosmic.internal.sqlite`, or
 * `cosmic.internal.debug` value, when the registry holds one under
 * `name`. Pushes it and returns 1, or pushes nothing and returns 0. */
static int raw_value(lua_State *L, const char *name) {
  lua_getfield(L, LUA_REGISTRYINDEX, RAW_TABLE);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    return 0;
  }
  lua_getfield(L, -1, name);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 2);
    return 0;
  }
  lua_remove(L, -2);
  return 1;
}

/* A loader that answers with its own upvalue, ignoring whatever it was
 * called with -- what a package.preload entry needs, since the preload
 * searcher calls it with a fixed "extra" of its own. */
static int return_upvalue(lua_State *L) {
  lua_pushvalue(L, lua_upvalueindex(1));
  return 1;
}

/* Reads one module's bytecode out of one database. Returns 1 with the
 * chunk on the stack, 0 when that database does not hold it, and -1 with
 * a message on the stack when the read itself failed.
 *
 * `is_binary` says whether `db` is the one attached to the running
 * executable, as opposed to a project's own build database. `*trusted`
 * is set to whether this load earns the raw store: compiled into the
 * binary's own tree, under `cosmic.*`, kind "module" or
 * "main". */
static int load_from(lua_State *L, sqlite3 *db, const char *name,
                     int is_binary, int *trusted) {
  static const char *query =
    "SELECT bytecode, kind FROM modules WHERE path = ?1";
  sqlite3_stmt *stmt = NULL;
  if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) != SQLITE_OK) {
    die_unreadable(db);
  }
  sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);

  int rc = sqlite3_step(stmt);
  if (rc == SQLITE_DONE) {
    sqlite3_finalize(stmt);
    return 0;
  }
  if (rc != SQLITE_ROW) {
    sqlite3_finalize(stmt);
    die_unreadable(db);
  }

  const void *bytes = sqlite3_column_blob(stmt, 0);
  int len = sqlite3_column_bytes(stmt, 0);
  const char *kind = (const char *)sqlite3_column_text(stmt, 1);
  *trusted = is_binary && names_trusted_kind(name, kind);
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
 * they are searched: index `count` is always the one attached to the
 * running binary, because `store_attach` only ever prepends. A name
 * under `cosmic.*` resolves there first and a project's own database
 * second, so a database that smuggles in a module of that name can
 * never shadow the binary's own -- everything else stays project
 * first, which is how a project overrides nothing it does not own.
 *
 * `cosmic.internal.store`, `cosmic.internal.sqlite`, and
 * `cosmic.internal.debug` are never rows in any database: they are the
 * raw C modules (`debug` opened by `cosmic_surface_open` and taken out
 * of reach the same way `io`/`os` are). Nothing ever resolves them by
 * name -- `require` would cache the result under that name
 * process-wide, which would then answer for an untrusted caller too.
 * Instead, loading `cosmic.store`, `cosmic.sqlite`, or `cosmic.coverage`
 * (the typed wrappers) from a trusted position hands the matching raw
 * value straight to that one chunk, as the `extra` argument `require`
 * always passes its loader. */
static int store_searcher(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  int reserved = strncmp(name, "cosmic.", 7) == 0;

  for (lua_Integer step = 0; step < count; step++) {
    lua_Integer i = reserved ? count - step : step + 1;
    sqlite3 *db = database_at(L, list, i);
    if (db == NULL) {
      continue;
    }
    int trusted = 0;
    int found = load_from(L, db, name, i == count, &trusted);
    if (found == 1) {
      const char *raw_name = NULL;
      if (trusted && strcmp(name, "cosmic.store") == 0) {
        raw_name = "cosmic.internal.store";
      } else if (trusted && strcmp(name, "cosmic.sqlite") == 0) {
        raw_name = "cosmic.internal.sqlite";
      } else if (trusted && strcmp(name, "cosmic.coverage") == 0) {
        raw_name = "cosmic.internal.debug";
      }
      if (raw_name != NULL && raw_value(L, raw_name)) {
        return 2;
      }
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
      die_unreadable(db);
    }
    sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);
    int rc = sqlite3_step(stmt);
    if (rc == SQLITE_ROW) {
      lua_pushlstring(L, sqlite3_column_blob(stmt, 0),
                      (size_t)sqlite3_column_bytes(stmt, 0));
      sqlite3_finalize(stmt);
      return 1;
    }
    if (rc != SQLITE_DONE) {
      sqlite3_finalize(stmt);
      die_unreadable(db);
    }
    sqlite3_finalize(stmt);
  }
  lua_pushnil(L);
  lua_pushfstring(L, "no module '%s' in the store", name);
  return 2;
}

/* One entry of the meta table, which is where the build records what it
 * decided: the main module's name, the hash of the tool. */
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
      die_unreadable(db);
    }
    sqlite3_bind_text(stmt, 1, key, -1, SQLITE_STATIC);
    int rc = sqlite3_step(stmt);
    if (rc == SQLITE_ROW) {
      lua_pushlstring(L, (const char *)sqlite3_column_text(stmt, 0),
                      (size_t)sqlite3_column_bytes(stmt, 0));
      sqlite3_finalize(stmt);
      return 1;
    }
    if (rc != SQLITE_DONE) {
      sqlite3_finalize(stmt);
      die_unreadable(db);
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

  /* The raw module never goes in package.preload -- that would be a
   * second door, open to anything that can `require`. It goes in the
   * registry instead, where only a trusted caller through the searcher
   * above can reach it. */
  open_store_module(L);
  cosmic_store_set_raw(L, "cosmic.internal.store");
  return 0;
}

void cosmic_store_set_raw(lua_State *L, const char *name) {
  lua_getfield(L, LUA_REGISTRYINDEX, RAW_TABLE);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_setfield(L, LUA_REGISTRYINDEX, RAW_TABLE);
  }
  lua_insert(L, -2);
  lua_setfield(L, -2, name);
  lua_pop(L, 1);
}

void cosmic_store_preload_raw(lua_State *L, const char *name) {
  if (!raw_value(L, name)) {
    return; /* nothing registered under this name */
  }
  /* package.preload's own searcher calls its entry with its own fixed
   * "extra" (":preload:"), not caller-supplied data, so the raw value
   * has to be a closed-over constant. */
  lua_pushcclosure(L, return_upvalue, 1);
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_insert(L, -2);
  lua_setfield(L, -2, name);
  lua_pop(L, 1);
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
