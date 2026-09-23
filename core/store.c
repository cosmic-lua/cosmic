#include "store.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "crypto.h"
#include "portable.h"
#include "sqlite.h"
#include "startup.h"

#define STORE_LIST "cosmic.store.databases"
#define STORE_ARTIFACT "cosmic.store.artifact"

#ifndef COSMIC_TARGET_NAME
#error "build.zig must define COSMIC_TARGET_NAME"
#endif

/* A prepare or a step that fails for a reason other than "no such row"
 * means the artifact database itself cannot be trusted -- truncated,
 * corrupted, or not a database at all despite its validated range. There is
 * no caller to hand that to: the process exits. */
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
 * `cosmic.store`, `cosmic.sqlite`, `cosmic.coverage`, `cosmic.hash`,
 * and `cosmic.compress` (the wrappers, one per raw module) get theirs
 * handed straight to their own loader
 * instead, as the `extra` argument `require` passes it. calling the
 * searcher by hand yields the same value, and that is no escalation:
 * the raw table holds nothing the wrapper does not already hand out. */
#define RAW_TABLE "cosmic.store.raw"

/* True when `name` is a path the binary's own tree owns and the kind is
 * one a running program actually executes -- what earns a module the
 * raw value behind its wrapper, handed at the moment it is loaded. */
static int names_trusted_kind(const char *name, const char *kind) {
  int reserved = strncmp(name, "cosmic.", 7) == 0 ||
                strncmp(name, "build.", 6) == 0;
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
 * binary's own tree, under `cosmic.*` or `build.*`, kind "module" or
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
 * `cosmic.internal.debug` are never rows in any database: they are raw
 * values `cosmic_surface_open` builds and registers directly (the
 * store module itself, the sqlite binding, and -- despite its name,
 * a holdover from when this raw name carried the real `debug` library
 * instead -- the native coverage collector, core/coverage.c). Nothing
 * ever resolves them by name -- `require` would cache the result under
 * that name
 * process-wide, which would then answer for an untrusted caller too.
 * Instead, loading `cosmic.store`, `cosmic.sqlite`, or `cosmic.coverage`
 * (the typed wrappers) from a trusted position hands the matching raw
 * value straight to that one chunk, as the `extra` argument `require`
 * always passes its loader. */
static int store_searcher(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  int reserved = strncmp(name, "cosmic.", 7) == 0 ||
                 strcmp(name, "build.artifact") == 0;

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
      } else if (trusted && strcmp(name, "cosmic.hash") == 0) {
        raw_name = "cosmic.internal.hash";
      } else if (trusted && strcmp(name, "cosmic.compress") == 0) {
        raw_name = "cosmic.internal.compress";
      } else if (trusted && strcmp(name, "build.artifact") == 0) {
        raw_name = "cosmic.internal.store";
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
  lua_pushliteral(L, "");
  return 2;
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
      lua_pushliteral(L, "");
      return 2;
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

/* One module's Teal source, or a declaration's, from the database
 * attached to the running binary and no other: what a checker building
 * some other tree needs in order to type a `require` of this one's
 * modules. Only the binary's rows answer, so a project's own database
 * can never stand in for the standard library's types. */
static int store_source(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  sqlite3 *db = count > 0 ? database_at(L, list, count) : NULL;
  static const char *queries[] = {
    "SELECT source FROM decls WHERE path = ?1",
    "SELECT source FROM modules WHERE path = ?1",
  };
  for (size_t i = 0; db != NULL && i < sizeof queries / sizeof *queries; i++) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, queries[i], -1, &stmt, NULL) != SQLITE_OK) {
      die_unreadable(db);
    }
    sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);
    int rc = sqlite3_step(stmt);
    if (rc == SQLITE_ROW) {
      lua_pushlstring(L, (const char *)sqlite3_column_text(stmt, 0),
                      (size_t)sqlite3_column_bytes(stmt, 0));
      sqlite3_finalize(stmt);
      lua_pushliteral(L, "");
      return 2;
    }
    if (rc != SQLITE_DONE) {
      sqlite3_finalize(stmt);
      die_unreadable(db);
    }
    sqlite3_finalize(stmt);
  }
  lua_pushnil(L);
  lua_pushfstring(L, "no module '%s' in the binary", name);
  return 2;
}

/* Pushes one database's meta value and returns 1, or pushes nothing and
 * returns 0 when that key has no row. */
static int database_meta(lua_State *L, sqlite3 *db, const char *key) {
  static const char *query = "SELECT value FROM meta WHERE key = ?1";
  sqlite3_stmt *stmt = NULL;
  if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) != SQLITE_OK)
    die_unreadable(db);
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
  return 0;
}

static void big_endian_32(unsigned char *out, uint32_t value) {
  out[0] = (unsigned char)(value >> 24);
  out[1] = (unsigned char)(value >> 16);
  out[2] = (unsigned char)(value >> 8);
  out[3] = (unsigned char)value;
}

static void big_endian_64(unsigned char *out, uint64_t value) {
  for (unsigned i = 0; i < 8; i++)
    out[i] = (unsigned char)(value >> (56 - 8 * i));
}

static void push_hex(lua_State *L, const unsigned char *bytes, size_t length) {
  static const char hex[] = "0123456789abcdef";
  luaL_Buffer buffer;
  char *text = luaL_buffinitsize(L, &buffer, length * 2);
  for (size_t i = 0; i < length; i++) {
    text[i * 2] = hex[bytes[i] >> 4];
    text[i * 2 + 1] = hex[bytes[i] & 15];
  }
  luaL_pushresultsize(&buffer, length * 2);
}

/* Portable runtime-v2 is an unambiguous, domain-separated encoding of the
 * validated physical core and the host-independent runtime basis:
 *
 *   "cosmic-runtime-v2" NUL, target:u32be, configuration:u32be,
 *   exact-raw-core-sha256[32], basis-length:u64be, basis bytes.
 */
static int push_portable_runtime(lua_State *L,
                                 const struct cosmic_artifact *artifact,
                                 int list) {
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  sqlite3 *binary = count > 0 ? database_at(L, list, count) : NULL;
  if (binary == NULL || !database_meta(L, binary, "runtime_basis")) {
    lua_pushnil(L);
    return 1;
  }
  size_t basis_length = 0;
  const char *basis = lua_tolstring(L, -1, &basis_length);
  static const char domain[] = "cosmic-runtime-v2";
  size_t fixed = sizeof domain + 4 + 4 + COSMIC_PORTABLE_SHA256_LENGTH + 8;
  if (basis == NULL || basis_length == 0 || basis_length > SIZE_MAX - fixed) {
    lua_pop(L, 1);
    lua_pushnil(L);
    return 1;
  }
  size_t encoded_length = fixed + basis_length;
  unsigned char *encoded = malloc(encoded_length);
  if (encoded == NULL) return luaL_error(L, "runtime identity: out of memory");
  size_t at = 0;
  memcpy(encoded + at, domain, sizeof domain);
  at += sizeof domain;
  big_endian_32(encoded + at, artifact->portable.selected.target_id);
  at += 4;
  big_endian_32(encoded + at,
                artifact->portable.selected.configuration_id);
  at += 4;
  memcpy(encoded + at, artifact->portable.selected.sha256,
         COSMIC_PORTABLE_SHA256_LENGTH);
  at += COSMIC_PORTABLE_SHA256_LENGTH;
  big_endian_64(encoded + at, (uint64_t)basis_length);
  at += 8;
  memcpy(encoded + at, basis, basis_length);

  unsigned char digest[COSMIC_DIGEST_MAX];
  size_t digest_length = 0;
  int status = cosmic_digest("sha256", encoded, encoded_length, digest,
                             &digest_length);
  free(encoded);
  lua_pop(L, 1);
  if (status != 0 || digest_length != COSMIC_PORTABLE_SHA256_LENGTH) {
    lua_pushnil(L);
    return 1;
  }
  push_hex(L, digest, digest_length);
  return 1;
}

static int push_binary_meta(lua_State *L, int list, const char *key) {
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  sqlite3 *binary = count > 0 ? database_at(L, list, count) : NULL;
  if (binary != NULL && database_meta(L, binary, key)) return 1;
  lua_pushnil(L);
  return 1;
}

/* Whether the artifact's selected core hashes to the digest its manifest
 * names, which is what a runtime identity is made of. A portable start checked
 * it before Lua ran; a host program is checked the first time it is asked.
 * The artifact is main's own, not a constant: the answer is remembered on it. */
static int core_identity_holds(const struct cosmic_artifact *artifact) {
  return cosmic_artifact_core_matches((struct cosmic_artifact *)artifact);
}

/* One entry of metadata. Runtime values come only from the validated artifact
 * context and its own final database, never from a project database searched
 * ahead of it. Other build metadata keeps ordinary database search order. */
static int store_meta(lua_State *L) {
  const char *key = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);

  lua_getfield(L, LUA_REGISTRYINDEX, STORE_ARTIFACT);
  const struct cosmic_artifact *artifact = lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (strcmp(key, "runtime_context") == 0) {
    if (artifact != NULL && artifact->fd >= 0 && artifact->host)
      lua_pushliteral(L, "host-v1");
    else if (artifact != NULL && artifact->fd >= 0)
      lua_pushliteral(L, "portable-v1");
    else
      lua_pushnil(L);
    return 1;
  }
  if (strcmp(key, "host") == 0 || strcmp(key, "host_image") == 0 ||
      strcmp(key, "runtime") == 0 || strcmp(key, "runtime_basis") == 0 ||
      strcmp(key, "artifact") == 0) {
    if (artifact == NULL || artifact->fd < 0) {
      lua_pushnil(L);
      return 1;
    }
    if (strcmp(key, "host") == 0) {
      lua_pushliteral(L, COSMIC_TARGET_NAME);
      return 1;
    }
    if ((strcmp(key, "host_image") == 0 || strcmp(key, "runtime") == 0) &&
        !core_identity_holds(artifact)) {
      lua_pushnil(L);
      return 1;
    }
    if (strcmp(key, "host_image") == 0) {
      push_hex(L, artifact->portable.selected.sha256,
               COSMIC_PORTABLE_SHA256_LENGTH);
      return 1;
    }
    if (strcmp(key, "runtime") == 0)
      return push_portable_runtime(L, artifact, list);
    if (strcmp(key, "runtime_basis") == 0)
      return push_binary_meta(L, list, "runtime_basis");
    lua_pushstring(L, artifact->logical_path);
    return 1;
  }

  for (lua_Integer i = 1; i <= count; i++) {
    sqlite3 *db = database_at(L, list, i);
    if (db != NULL && database_meta(L, db, key)) return 1;
  }
  lua_pushnil(L);
  return 1;
}

/* Every database `require` searches, in search order, each as a
 * borrowed `cosmic.sqlite` handle: what a verb that reads the shipped
 * tables -- `cosmic docs` over `docs` and `uses` -- queries, without a
 * path to any of them, since the binary's own is inside the binary.
 * The handles read only; `close` on one is a no-op, and the store
 * keeps the connections for as long as the process runs. */
static int store_databases(lua_State *L) {
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  lua_createtable(L, (int)count, 0);
  for (lua_Integer i = 1; i <= count; i++) {
    sqlite3 *db = database_at(L, list, i);
    if (db == NULL) {
      continue;
    }
    cosmic_sqlite_push_borrowed(L, db);
    lua_seti(L, -2, i);
  }
  return 1;
}

/* Private capability handed only to the trusted build.artifact chunk. */
static int store_trusted_prefix(lua_State *L) {
  const struct cosmic_artifact *artifact =
      lua_touserdata(L, lua_upvalueindex(1));
  if (artifact == NULL || artifact->fd < 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "no retained portable artifact");
    return 2;
  }
  if (artifact->host) {
    lua_pushnil(L);
    lua_pushliteral(L, "a host program carries only its own core, not the "
                       "portable prefix a portable program is made from");
    return 2;
  }
  uint64_t length = artifact->portable.prefix_length;
  if (length > (uint64_t)SIZE_MAX) {
    lua_pushnil(L);
    lua_pushliteral(L, "retained portable prefix is too large");
    return 2;
  }
  /* Startup binds the executing cached core to its manifest identity. Prefix
   * reuse has a stronger requirement: every raw core will be copied into a
   * future artifact, so verify every exact retained range before exposing any
   * prefix bytes. This stays lazy so an otherwise valid warm cached core can
   * run commands that do not reuse a corrupt artifact prefix. */
  for (uint32_t i = 0; i < artifact->portable.entry_count; i++) {
    const struct cosmic_portable_entry *entry = &artifact->portable.entries[i];
    unsigned char digest[COSMIC_DIGEST_MAX];
    size_t digest_length = 0;
    if (cosmic_digest_fd("sha256", artifact->fd, entry->offset, entry->length,
                         digest, &digest_length) != 0 ||
        digest_length != COSMIC_PORTABLE_SHA256_LENGTH ||
        memcmp(digest, entry->sha256, digest_length) != 0) {
      lua_pushnil(L);
      lua_pushfstring(L,
                      "retained portable core range %d digest differs from manifest",
                      (int)i + 1);
      return 2;
    }
  }
  luaL_Buffer buffer;
  char *bytes = luaL_buffinitsize(L, &buffer, (size_t)length);
  if (!cosmic_artifact_read(artifact, bytes, (size_t)length, 0)) {
    luaL_pushresultsize(&buffer, 0);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushliteral(L, "retained portable prefix cannot be read");
    return 2;
  }
  luaL_pushresultsize(&buffer, (size_t)length);
  lua_pushliteral(L, "");
  return 2;
}

/* Private capability handed only to the trusted build.artifact chunk: the
 * running core's exact bytes, checked against its manifest digest, and the
 * identity a host program made from them declares. */
static int store_trusted_core(lua_State *L) {
  const struct cosmic_artifact *artifact =
      lua_touserdata(L, lua_upvalueindex(1));
  if (artifact == NULL || artifact->fd < 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "no retained artifact to take a core from");
    return 2;
  }
  const struct cosmic_portable_entry *entry = &artifact->portable.selected;
  if (entry->length > (uint64_t)SIZE_MAX) {
    lua_pushnil(L);
    lua_pushliteral(L, "running core is too large");
    return 2;
  }
  if (!core_identity_holds(artifact)) {
    lua_pushnil(L);
    lua_pushliteral(L, "running core's digest differs from its manifest");
    return 2;
  }
  lua_createtable(L, 0, 4);
  luaL_Buffer buffer;
  char *bytes = luaL_buffinitsize(L, &buffer, (size_t)entry->length);
  if (!cosmic_artifact_read(artifact, bytes, (size_t)entry->length,
                            entry->offset)) {
    luaL_pushresultsize(&buffer, 0);
    lua_pop(L, 2);
    lua_pushnil(L);
    lua_pushliteral(L, "running core cannot be read");
    return 2;
  }
  luaL_pushresultsize(&buffer, (size_t)entry->length);
  lua_setfield(L, -2, "bytes");
  lua_pushinteger(L, (lua_Integer)entry->target_id);
  lua_setfield(L, -2, "target_id");
  lua_pushinteger(L, (lua_Integer)entry->configuration_id);
  lua_setfield(L, -2, "configuration_id");
  lua_pushlstring(L, (const char *)entry->sha256, COSMIC_PORTABLE_SHA256_LENGTH);
  lua_setfield(L, -2, "digest");
  lua_pushliteral(L, "");
  return 2;
}

static int open_store_module(lua_State *L,
                             const struct cosmic_artifact *artifact) {
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
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, store_source, 1);
  lua_setfield(L, -2, "source");
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, store_databases, 1);
  lua_setfield(L, -2, "databases");
  lua_pushlightuserdata(L, (void *)artifact);
  lua_pushcclosure(L, store_trusted_prefix, 1);
  lua_setfield(L, -2, "trusted_prefix");
  lua_pushlightuserdata(L, (void *)artifact);
  lua_pushcclosure(L, store_trusted_core, 1);
  lua_setfield(L, -2, "trusted_core");
  lua_remove(L, -2);
  return 1;
}

int cosmic_store_count(lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, STORE_LIST);
  int count = (int)lua_rawlen(L, -1);
  lua_pop(L, 1);
  return count;
}

const struct cosmic_artifact *cosmic_store_artifact(lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, STORE_ARTIFACT);
  const struct cosmic_artifact *artifact = lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (artifact == NULL || artifact->fd < 0) return NULL;
  return artifact;
}

sqlite3 *cosmic_store_database(lua_State *L, int index) {
  lua_getfield(L, LUA_REGISTRYINDEX, STORE_LIST);
  sqlite3 *db = database_at(L, -1, index);
  lua_pop(L, 1);
  return db;
}

int cosmic_store_install(lua_State *L, sqlite3 *binary,
                         const struct cosmic_artifact *artifact) {
  lua_newtable(L);
  if (binary != NULL) {
    lua_pushlightuserdata(L, binary);
    lua_seti(L, -2, 1);
  }
  lua_pushvalue(L, -1);
  lua_setfield(L, LUA_REGISTRYINDEX, STORE_LIST);
  if (artifact == NULL) lua_pushnil(L);
  else lua_pushlightuserdata(L, (void *)artifact);
  lua_setfield(L, LUA_REGISTRYINDEX, STORE_ARTIFACT);

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
  open_store_module(L, artifact);
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
