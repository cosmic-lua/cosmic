#include "sqlite.h"

#include <limits.h>
#include <string.h>

#include "lauxlib.h"
#include "crypto.h"
#include "sqlite3.h"

#define HANDLE_TYPE "cosmic.sqlite.handle"
#define STATEMENT_TYPE "cosmic.sqlite.statement"

struct handle {
  sqlite3 *db;
  /* Set when the connection belongs to someone else (the store): this
   * handle reads through it and never closes it. */
  int borrowed;
};

struct statement {
  sqlite3_stmt *stmt;
  sqlite3 *db;
};

static int failed(lua_State *L, sqlite3 *db, int rc) {
  lua_pushnil(L);
  if (db != NULL) {
    lua_pushstring(L, sqlite3_errmsg(db));
  } else {
    lua_pushstring(L, sqlite3_errstr(rc));
  }
  return 2;
}

static int failed_effect(lua_State *L, sqlite3 *db, int rc) {
  lua_pushboolean(L, 0);
  if (db != NULL) {
    lua_pushstring(L, sqlite3_errmsg(db));
  } else {
    lua_pushstring(L, sqlite3_errstr(rc));
  }
  return 2;
}

static int succeeded(lua_State *L) {
  lua_pushliteral(L, "");
  return 2;
}

static struct handle *checked_handle(lua_State *L) {
  struct handle *h = luaL_checkudata(L, 1, HANDLE_TYPE);
  if (h->db == NULL) {
    luaL_error(L, "the database handle is closed"); /* throws: a use after
                                                       close is a bug, not a
                                                       runtime failure */
  }
  return h;
}

static struct statement *checked_statement(lua_State *L) {
  struct statement *s = luaL_checkudata(L, 1, STATEMENT_TYPE);
  if (s->stmt == NULL) {
    luaL_error(L, "the statement is finalized"); /* throws: as above */
  }
  return s;
}

/* The digest functions, registered on every handle this module opens,
 * so a build hashes inside the database it is writing rather than
 * round-tripping bytes out to Lua and back: `sha256(X)` is the 32-byte
 * digest of a text or blob; `digest(A, X)` the digest under the
 * algorithm named A; `hmac(A, K, X)` the HMAC of X under key K over
 * A. A NULL among the arguments gives NULL; an algorithm no one has
 * heard of is an error. */
static void finish_digest(sqlite3_context *ctx, int status,
                          const unsigned char *digest, size_t len) {
  if (status == -1) {
    sqlite3_result_error(ctx, "no such digest algorithm", -1);
    return;
  }
  if (status != 0) {
    sqlite3_result_error(ctx, "the digest failed", -1);
    return;
  }
  sqlite3_result_blob(ctx, digest, (int)len, SQLITE_TRANSIENT);
}

static int any_null(int argc, sqlite3_value **argv) {
  for (int i = 0; i < argc; i++) {
    if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
      return 1;
    }
  }
  return 0;
}

/* A value's bytes, with an empty text or blob as a valid empty span
 * rather than a NULL pointer. */
static const void *bytes_of(sqlite3_value *value, size_t *len) {
  const void *data = sqlite3_value_blob(value);
  *len = (size_t)sqlite3_value_bytes(value);
  return data == NULL ? "" : data;
}

static void sha256_function(sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  size_t len;
  const void *data = bytes_of(argv[0], &len);
  unsigned char digest[COSMIC_DIGEST_MAX];
  size_t digest_len = 0;
  int status = cosmic_digest("sha256", data, len, digest, &digest_len);
  finish_digest(ctx, status, digest, digest_len);
}

static void digest_function(sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  const char *name = (const char *)sqlite3_value_text(argv[0]);
  size_t len;
  const void *data = bytes_of(argv[1], &len);
  unsigned char digest[COSMIC_DIGEST_MAX];
  size_t digest_len = 0;
  int status = cosmic_digest(name, data, len, digest, &digest_len);
  finish_digest(ctx, status, digest, digest_len);
}

static void hmac_function(sqlite3_context *ctx, int argc,
                          sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  const char *name = (const char *)sqlite3_value_text(argv[0]);
  size_t key_len;
  const void *key = bytes_of(argv[1], &key_len);
  size_t len;
  const void *data = bytes_of(argv[2], &len);
  unsigned char mac[COSMIC_DIGEST_MAX];
  size_t mac_len = 0;
  int status = cosmic_hmac(name, key, key_len, data, len, mac, &mac_len);
  finish_digest(ctx, status, mac, mac_len);
}

struct function {
  const char *name;
  int arity;
  void (*call)(sqlite3_context *, int, sqlite3_value **);
};

static const struct function functions[] = {
    {"sha256", 1, sha256_function},
    {"digest", 2, digest_function},
    {"hmac", 3, hmac_function},
};

static int sqlite_open(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int writable = lua_toboolean(L, 2);
  /* No SQLITE_OPEN_URI: `path` is an ordinary filename, never a `file:`
   * URI. M1 documents no URI form, so `vfs=`, `off=` and `len=` are
   * never parsed out of a caller's path at all, not even refused. */
  int flags = writable ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
                       : SQLITE_OPEN_READONLY;

  struct handle *h = lua_newuserdatauv(L, sizeof *h, 0);
  h->db = NULL;
  h->borrowed = 0;
  luaL_setmetatable(L, HANDLE_TYPE);

  int rc = sqlite3_open_v2(path, &h->db, flags, NULL);
  /* Another process may hold the file's lock: two builds of one tree, or a
   * reader meeting a writer's commit. Wait for it rather than failing. */
  if (rc == SQLITE_OK) rc = sqlite3_busy_timeout(h->db, 60000);
  for (size_t i = 0; rc == SQLITE_OK && i < sizeof functions / sizeof *functions;
       i++) {
    rc = sqlite3_create_function(
        h->db, functions[i].name, functions[i].arity,
        SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_DIRECTONLY, NULL,
        functions[i].call, NULL, NULL);
  }
  if (rc != SQLITE_OK) {
    int result = failed(L, h->db, rc);
    sqlite3_close_v2(h->db);
    h->db = NULL;
    return result;
  }
  return succeeded(L);
}

static int handle_exec(lua_State *L) {
  struct handle *h = checked_handle(L);
  const char *sql = luaL_checkstring(L, 2);
  char *message = NULL;
  int rc = sqlite3_exec(h->db, sql, NULL, NULL, &message);
  if (rc != SQLITE_OK) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, message == NULL ? sqlite3_errstr(rc) : message);
    sqlite3_free(message);
    return 2;
  }
  lua_pushboolean(L, 1);
  return succeeded(L);
}

static int handle_prepare(lua_State *L) {
  struct handle *h = checked_handle(L);
  size_t len;
  const char *sql = luaL_checklstring(L, 2, &len);
  if (len > INT_MAX) {
    lua_pushnil(L);
    lua_pushstring(L, "SQL is too long");
    return 2;
  }
  if (memchr(sql, '\0', len) != NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "SQL contains an embedded NUL byte");
    return 2;
  }
  struct statement *s = lua_newuserdatauv(L, sizeof *s, 1);
  s->stmt = NULL;
  s->db = h->db;
  luaL_setmetatable(L, STATEMENT_TYPE);
  /* The statement holds a reference to its handle, so the handle cannot
   * be collected while a statement is still open on it. */
  lua_pushvalue(L, 1);
  lua_setiuservalue(L, -2, 1);

  const char *tail = NULL;
  int rc = sqlite3_prepare_v2(h->db, sql, (int)len, &s->stmt, &tail);
  if (rc != SQLITE_OK) {
    return failed(L, h->db, rc);
  }
  if (s->stmt == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "SQL contains no statement");
    return 2;
  }

  sqlite3_stmt *extra = NULL;
  const char *end = sql + len;
  rc = sqlite3_prepare_v2(h->db, tail, (int)(end - tail), &extra, NULL);
  if (rc != SQLITE_OK) {
    lua_pushnil(L);
    lua_pushstring(L, sqlite3_errmsg(h->db));
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
    return 2;
  }
  if (extra != NULL) {
    sqlite3_finalize(extra);
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
    lua_pushnil(L);
    lua_pushstring(L, "SQL contains more than one statement");
    return 2;
  }
  return succeeded(L);
}

static int handle_close(lua_State *L) {
  struct handle *h = luaL_checkudata(L, 1, HANDLE_TYPE);
  if (h->db == NULL) {
    lua_pushboolean(L, 1);
    return succeeded(L);
  }
  if (h->borrowed) {
    h->db = NULL;
    lua_pushboolean(L, 1);
    return succeeded(L);
  }
  int rc = sqlite3_close(h->db);
  if (rc != SQLITE_OK) {
    return failed_effect(L, h->db, rc);
  }
  h->db = NULL;
  lua_pushboolean(L, 1);
  return succeeded(L);
}

static int handle_gc(lua_State *L) {
  struct handle *h = luaL_checkudata(L, 1, HANDLE_TYPE);
  if (h->db != NULL && !h->borrowed) {
    sqlite3_close_v2(h->db);
  }
  h->db = NULL;
  return 0;
}

void cosmic_sqlite_push_borrowed(lua_State *L, sqlite3 *db) {
  struct handle *h = lua_newuserdatauv(L, sizeof *h, 0);
  h->db = db;
  h->borrowed = 1;
  luaL_setmetatable(L, HANDLE_TYPE);
}

static int handle_changes(lua_State *L) {
  struct handle *h = checked_handle(L);
  lua_pushinteger(L, (lua_Integer)sqlite3_changes64(h->db));
  return 1;
}

static int handle_last_insert_rowid(lua_State *L) {
  struct handle *h = checked_handle(L);
  lua_pushinteger(L, (lua_Integer)sqlite3_last_insert_rowid(h->db));
  return 1;
}

static int bound(lua_State *L, int rc, sqlite3 *db) {
  if (rc != SQLITE_OK) {
    return failed_effect(L, db, rc);
  }
  lua_pushboolean(L, 1);
  return succeeded(L);
}

static int statement_parameters(lua_State *L) {
  struct statement *s = checked_statement(L);
  lua_pushinteger(L, sqlite3_bind_parameter_count(s->stmt));
  return 1;
}

static int statement_bind_null(lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = (int)luaL_checkinteger(L, 2);
  return bound(L, sqlite3_bind_null(s->stmt, index), s->db);
}

static int statement_bind_integer(lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = (int)luaL_checkinteger(L, 2);
  lua_Integer value = luaL_checkinteger(L, 3);
  return bound(L, sqlite3_bind_int64(s->stmt, index, (sqlite3_int64)value),
               s->db);
}

static int statement_bind_number(lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = (int)luaL_checkinteger(L, 2);
  lua_Number value = luaL_checknumber(L, 3);
  return bound(L, sqlite3_bind_double(s->stmt, index, (double)value), s->db);
}

static int statement_bind_text(lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = (int)luaL_checkinteger(L, 2);
  size_t len;
  const char *value = luaL_checklstring(L, 3, &len);
  return bound(L,
               sqlite3_bind_text64(s->stmt, index, value, (sqlite3_uint64)len,
                                   SQLITE_TRANSIENT, SQLITE_UTF8),
               s->db);
}

static int statement_bind_blob(lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = (int)luaL_checkinteger(L, 2);
  size_t len;
  const char *value = luaL_checklstring(L, 3, &len);
  return bound(L,
               sqlite3_bind_blob64(s->stmt, index, value, (sqlite3_uint64)len,
                                   SQLITE_TRANSIENT),
               s->db);
}

static int statement_step(lua_State *L) {
  struct statement *s = checked_statement(L);
  int rc = sqlite3_step(s->stmt);
  if (rc == SQLITE_ROW) {
    lua_pushstring(L, "row");
    return succeeded(L);
  }
  if (rc == SQLITE_DONE) {
    lua_pushstring(L, "done");
    return succeeded(L);
  }
  return failed(L, s->db, rc);
}

static int statement_columns(lua_State *L) {
  struct statement *s = checked_statement(L);
  lua_pushinteger(L, sqlite3_column_count(s->stmt));
  return 1;
}

static int statement_kind(lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = (int)luaL_checkinteger(L, 2);
  const char *name;
  switch (sqlite3_column_type(s->stmt, index)) {
    case SQLITE_INTEGER: name = "integer"; break;
    case SQLITE_FLOAT: name = "number"; break;
    case SQLITE_TEXT: name = "text"; break;
    case SQLITE_BLOB: name = "blob"; break;
    default: name = "null"; break;
  }
  lua_pushstring(L, name);
  return 1;
}

static int statement_integer(lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = (int)luaL_checkinteger(L, 2);
  lua_pushinteger(L, (lua_Integer)sqlite3_column_int64(s->stmt, index));
  return 1;
}

static int statement_number(lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = (int)luaL_checkinteger(L, 2);
  lua_pushnumber(L, (lua_Number)sqlite3_column_double(s->stmt, index));
  return 1;
}

/* Text and blob read the same bytes; they are two calls so the caller
 * says which it expects and a blob never arrives silently as text. */
static int statement_bytes(lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = (int)luaL_checkinteger(L, 2);
  const void *data = sqlite3_column_blob(s->stmt, index);
  int len = sqlite3_column_bytes(s->stmt, index);
  if (data == NULL && len == 0) {
    lua_pushliteral(L, "");
  } else {
    lua_pushlstring(L, data, (size_t)len);
  }
  return 1;
}

static int statement_reset(lua_State *L) {
  struct statement *s = checked_statement(L);
  sqlite3_clear_bindings(s->stmt);
  int rc = sqlite3_reset(s->stmt);
  if (rc != SQLITE_OK) {
    return failed_effect(L, s->db, rc);
  }
  lua_pushboolean(L, 1);
  return succeeded(L);
}

static int statement_finalize(lua_State *L) {
  struct statement *s = luaL_checkudata(L, 1, STATEMENT_TYPE);
  if (s->stmt != NULL) {
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int statement_gc(lua_State *L) {
  struct statement *s = luaL_checkudata(L, 1, STATEMENT_TYPE);
  if (s->stmt != NULL) {
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
  }
  return 0;
}

static const luaL_Reg handle_methods[] = {
    {"exec", handle_exec},     {"prepare", handle_prepare},
    {"close", handle_close},   {"changes", handle_changes},
    {"last_insert_rowid", handle_last_insert_rowid},
    {NULL, NULL},
};

static const luaL_Reg statement_methods[] = {
    {"parameters", statement_parameters},
    {"bind_null", statement_bind_null},
    {"bind_integer", statement_bind_integer},
    {"bind_number", statement_bind_number},
    {"bind_text", statement_bind_text},
    {"bind_blob", statement_bind_blob},
    {"step", statement_step},
    {"columns", statement_columns},
    {"kind", statement_kind},
    {"integer", statement_integer},
    {"number", statement_number},
    {"bytes", statement_bytes},
    {"reset", statement_reset},
    {"finalize", statement_finalize},
    {NULL, NULL},
};

static void make_type(lua_State *L, const char *name, const luaL_Reg *methods,
                      lua_CFunction collect) {
  luaL_newmetatable(L, name);
  lua_pushcfunction(L, collect);
  lua_setfield(L, -2, "__gc");
  lua_pushstring(L, name);
  lua_setfield(L, -2, "__name");
  lua_newtable(L);
  luaL_setfuncs(L, methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
}

static const luaL_Reg module[] = {
    {"open", sqlite_open},
    {NULL, NULL},
};

int cosmic_open_sqlite(lua_State *L) {
  sqlite3_initialize();
  make_type(L, HANDLE_TYPE, handle_methods, handle_gc);
  make_type(L, STATEMENT_TYPE, statement_methods, statement_gc);
  luaL_newlib(L, module);
  lua_pushstring(L, sqlite3_libversion());
  lua_setfield(L, -2, "version");
  return 1;
}
