#define _POSIX_C_SOURCE 200809L /* unsetenv */

#include "store.h"

#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "assertions.h"
#include "check.h"
#include "fail.h"
#include "lauxlib.h"
#include "compress.h"
#include "coverage.h"
#include "crypto.h"
#include "executable.h"
#include "hash.h"
#include "html.h"
#include "process.h"
#include "socket.h"
#include "http.h"
#include "json.h"
#include "guard.h"
#include "memory.h"
#include "portable.h"
#include "sqlite.h"
#include "startup.h"
#include "surface.h"
#include "vector.h"
#include "xml.h"

#define STORE_LIST "cosmic.store.databases"
#define STORE_ARTIFACT "cosmic.store.artifact"
#ifndef COSMIC_TARGET_NAME
#error "build.zig must define COSMIC_TARGET_NAME"
#endif

/* A prepare or a step that fails for a reason other than "no such row"
 * means the artifact database itself cannot be trusted -- truncated,
 * corrupted, or not a database at all despite its validated range. There is
 * no caller to hand that to: the process exits. */
static _Noreturn void die_unreadable (sqlite3 *db) {
  fprintf(stderr, "cosmic: the attached database is unreadable: %s\n",
          sqlite3_errmsg(db));
  exit(2); /* exits: a database this broken has no well-formed answer to
              return, honest or otherwise */
}

/* Whether a prepare or a step failed for memory rather than for the
 * database: SQLite's own allocation refused. That is the process out of
 * memory, which raises like any allocation, not a database to die of. */
static bool out_of_memory (int rc) { return (rc & 0xff) == SQLITE_NOMEM; }

/* Where the raw `cosmic.internal.*` values live, and who may take one.
 *
 * Most of them are plain modules: `require("cosmic.internal.process")`
 * answers the C table, which the module's declaration
 * (cosmic/internal/process.d.tl) types, and `require` caches it like any
 * other. What keeps a project from requiring one is the build, not the
 * store: a project's program is checked (build/project_refusals.tl) and
 * may not `require` anything under `cosmic.internal`, by a name it
 * computes, through `package`, `debug`, `_G` or `_ENV`, or in a chunk of
 * bytecode, and a chunk that `load` builds with no environment has no
 * `require` at all (core/surface.c). Calling the searcher by hand always
 * yielded the same table, so nothing is escalated: the process table's
 * `waitpid` can reap a child no handle of the caller's owns, which
 * [`cosmic.child`] never does, but that is a caller breaking its own
 * bookkeeping, and why the table is off the public surface, not a
 * privilege gained. A project module is no longer refused a raw table at
 * load time: containment is that static rule alone.
 *
 * The four values that steer the process itself are never plain, since
 * `require` would cache them process-wide for any caller: the store (to
 * attach a database, and so to change what `require` loads), the
 * coverage collector's hook, the instruction budget's, and the counting
 * `assert`. Each is handed straight to the loader of the wrappers
 * `raw_modules` lists, as the `extra` argument `require` passes it, and
 * only when that wrapper is loaded trusted. */
#define RAW_TABLE "cosmic.store.raw"

/* Every raw value, in the order it is opened. `open` builds it; it is NULL
 * where other code registers it -- [`cosmic_store_install`] the store,
 * core/surface.c the collector (its raw name, [`cosmic.internal.debug`],
 * holds no debug library). `plain` says `require` answers it by its name. */
static const struct raw_value {
  const char *raw;
  lua_CFunction open;
  int plain;
} raw_values[] = {
  {"cosmic.internal.store", NULL, 0},
  {"cosmic.internal.debug", NULL, 0},
  {"cosmic.internal.sqlite", cosmic_open_sqlite, 1},
  {"cosmic.internal.hash", cosmic_open_hash, 1},
  {"cosmic.internal.html", cosmic_open_html, 1},
  {"cosmic.internal.vector", cosmic_open_vector, 1},
  {"cosmic.internal.process", cosmic_open_process, 1},
  {"cosmic.internal.compress", cosmic_open_compress, 1},
  {"cosmic.internal.http", cosmic_open_http, 1},
  {"cosmic.internal.socket", cosmic_open_socket, 1},
  {"cosmic.internal.json", cosmic_open_json, 1},
  {"cosmic.internal.xml", cosmic_open_xml, 1},
  {"cosmic.internal.budget", cosmic_open_budget, 0},
  {"cosmic.internal.assertions", cosmic_open_assertions, 0},
};
#define RAW_VALUE_COUNT (sizeof raw_values / sizeof *raw_values)

/* Every wrapper that is handed a raw value when loaded trusted, and the
 * raw value's name. Being listed here is also what reserves a name
 * outside `cosmic.*` for the binary's own tree ([`names_reserved`]), so
 * one entry is the whole grant: a project database can never shadow a
 * wrapper named here, and any `build.*` name not named here stays
 * project first. [`build.test_worker`] gets the store's to attach the
 * store its test is given, as a loader no test can replace.
 * [`build.coverage_hits`] gets the collector's, to read the open window
 * in place, which [`cosmic.coverage`] does not offer. [`build.assertions`]
 * gets the counting `assert`. [`build.fuzz`] gets the instruction budget
 * alone, which shares the coverage collector's hook but none of its
 * collection. */
static const struct raw_module {
  const char *wrapper;
  const char *raw;
} raw_modules[] = {
  {"cosmic.store", "cosmic.internal.store"},
  {"build.artifact", "cosmic.internal.store"},
  {"build.test_worker", "cosmic.internal.store"},
  {"cosmic.coverage", "cosmic.internal.debug"},
  {"build.coverage_hits", "cosmic.internal.debug"},
  {"build.fuzz", "cosmic.internal.budget"},
  {"build.assertions", "cosmic.internal.assertions"},
};
#define RAW_MODULE_COUNT (sizeof raw_modules / sizeof *raw_modules)

/* The harness modules that were wrappers of a raw value and still must not
 * be shadowed by a project's database: [`build.digest`] computes the key
 * of a verdict and [`build.confine`] confines each child a test starts. */
static const char *const reserved_build[] = {"build.confine", "build.digest"};

/* Whether `name` is a raw value `require` answers by its name. */
static int names_plain_raw (const char *name) {
  for (size_t v = 0; v < RAW_VALUE_COUNT; v++) {
    if (raw_values[v].plain && strcmp(name, raw_values[v].raw) == 0) {
      return 1;
    }
  }
  return 0;
}

/* True when `name` resolves from the binary's own database ahead of any
 * project's: everything under `cosmic.*`, and every wrapper in
 * `raw_modules`, which a project could otherwise shadow with a module of
 * its own that loads untrusted and without its raw value. */
static int names_reserved (const char *name) {
  if (strncmp(name, "cosmic.", 7) == 0) {
    return 1;
  }
  for (size_t m = 0; m < sizeof reserved_build / sizeof *reserved_build; m++) {
    if (strcmp(name, reserved_build[m]) == 0) {
      return 1;
    }
  }
  for (size_t m = 0; m < RAW_MODULE_COUNT; m++) {
    if (strcmp(name, raw_modules[m].wrapper) == 0) {
      return 1;
    }
  }
  return 0;
}

/* True when `name` is a path the binary's own tree owns and the kind is
 * one a running program actually executes -- what earns a module the
 * raw value behind its wrapper, handed at the moment it is loaded. */
static int names_trusted_kind (const char *name, const char *kind) {
  int reserved = strncmp(name, "cosmic.", 7) == 0 ||
                strncmp(name, "build.", 6) == 0;
  int runnable = kind != NULL &&
                (strcmp(kind, "module") == 0 || strcmp(kind, "main") == 0);
  return reserved && runnable;
}

/* The raw value registered under `name`, when the registry holds one.
 * Pushes it and returns 1, or pushes nothing and returns 0. */
static int raw_value (lua_State *L, const char *name) {
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

/* The raw value handed to the loader of `name`: the value of its row in
 * `raw_modules`. Pushes it and returns 1, or pushes nothing and returns 0
 * where no row of the wrapper has a value. */
static int wrapper_raw (lua_State *L, const char *name) {
  for (size_t m = 0; m < RAW_MODULE_COUNT; m++) {
    if (strcmp(name, raw_modules[m].wrapper) == 0 &&
        raw_value(L, raw_modules[m].raw)) {
      return 1;
    }
  }
  return 0;
}

/* A loader that answers with its own upvalue, ignoring whatever it was
 * called with -- what a package.preload entry needs, since the preload
 * searcher calls it with a fixed "extra" of its own. */
static int return_upvalue (lua_State *L) {
  lua_pushvalue(L, lua_upvalueindex(1));
  return 1;
}

/* No more than the database would hold as one value, so a stream that
 * decodes to more fails before it is all in memory, as `inflate` in SQL
 * does ([`core/sqlite.c`]). */
static size_t inflate_limit (sqlite3 *db) {
  return (size_t)sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1);
}

/* Reads one module's bytecode out of one database, inflating it. Returns 1
 * with the chunk on the stack, 0 when that database does not hold it, and
 * -1 with a message on the stack when the read itself failed.
 *
 * `is_binary` says whether `db` is the one attached to the running
 * executable, as opposed to a project's own build database. `*trusted`
 * is set to whether this load earns the raw store: compiled into the
 * binary's own tree, under `cosmic.*` or `build.*`, kind "module" or
 * "main". */
static int load_from (lua_State *L, sqlite3 *db, const char *name,
                      int is_binary, int *trusted) {
  static const char *query =
    "SELECT bytecode, kind FROM main.modules WHERE path = ?1";
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(db, query, -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    sqlite3_finalize(stmt);
    if (out_of_memory(rc)) {
      lua_pushliteral(L, "not enough memory");
      return -1;
    }
    die_unreadable(db);
  }
  sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);

  rc = sqlite3_step(stmt);
  if (rc == SQLITE_DONE) {
    sqlite3_finalize(stmt);
    return 0;
  }
  if (rc != SQLITE_ROW) {
    sqlite3_finalize(stmt);
    if (out_of_memory(rc)) {
      lua_pushliteral(L, "not enough memory");
      return -1;
    }
    die_unreadable(db);
  }

  /* The blob first, then its length: the length describes the value the
   * blob call converted. A NULL pointer with a length is SQLite out of
   * memory, never bytes to load. */
  const void *bytes = sqlite3_column_blob(stmt, 0);
  int len = sqlite3_column_bytes(stmt, 0);
  if (bytes == NULL && len > 0) {
    sqlite3_finalize(stmt);
    lua_pushliteral(L, "not enough memory");
    return -1;
  }
  const char *kind = (const char *)sqlite3_column_text(stmt, 1);
  *trusted = is_binary && names_trusted_kind(name, kind);
  /* The build stores bytecode deflated ([`build.writer`]). Inflated into
   * a block of its own, so the statement is finalized before anything can
   * fail; the block is freed right after `luaL_loadbufferx`, which runs
   * protected and so returns, never raises, with it in hand. */
  unsigned char *code = NULL;
  size_t code_len = 0;
  const char *why = cosmic_inflate_raw(
    bytes, (size_t)len, inflate_limit(db), &code, &code_len);
  sqlite3_finalize(stmt);
  if (why != NULL) {
    /* Memory running out is told as every other path of this function
     * tells it, not as the module's fault. */
    if (strcmp(why, "not enough memory") == 0) {
      lua_pushliteral(L, "not enough memory");
    }
    else {
      lua_pushfstring(L, "bad bytecode of module '%s': %s", name, why);
    }
    return -1;
  }
  char chunk[256];
  snprintf(chunk, sizeof chunk, "@%s", name);
  int loaded = luaL_loadbufferx(L, (const char *)code, code_len, chunk, "b");
  cosmic_free(code);
  if (loaded != LUA_OK) {
    return -1;
  }
  return 1;
}

static sqlite3 *database_at (lua_State *L, int list, lua_Integer index) {
  lua_geti(L, list, index);
  sqlite3 *db = lua_touserdata(L, -1);
  lua_pop(L, 1);
  return db;
}

/* The binary's own database, the last of the list at `list`, or NULL
 * when there is none. */
static sqlite3 *binary_database (lua_State *L, int list) {
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  return count > 0 ? database_at(L, list, count) : NULL;
}

/* The one searcher. Its upvalue is the list of databases, in the order
 * they are searched: index `count` is always the one attached to the
 * running binary, because [`store_attach`] only ever prepends. A reserved
 * name ([`names_reserved`]: under `cosmic.*`, or a wrapper in
 * `raw_modules`) resolves there first and a project's own database
 * second, so a database that smuggles in a module of that name can never
 * shadow the binary's own -- everything else stays project first, which
 * is how a project overrides nothing it does not own.
 *
 * The raw `cosmic.internal.*` values are never rows in any database:
 * core C builds and registers them directly (see `raw_values`). A plain
 * one ([`names_plain_raw`]) is answered by its name ahead of every
 * database, so none can shadow it. Loading one of `raw_modules`'
 * wrappers from a trusted position instead hands the matching raw value
 * straight to that one chunk, as the `extra` argument `require` always
 * passes its loader. */
static int store_searcher (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  int reserved = names_reserved(name);

  if (names_plain_raw(name) && raw_value(L, name)) {
    /* The value itself, as a module's: `require` caches it under its name. */
    lua_pushcclosure(L, return_upvalue, 1);
    lua_pushstring(L, name);
    return 2;
  }
  for (lua_Integer step = 0; step < count; step++) {
    lua_Integer i = reserved ? count - step : step + 1;
    sqlite3 *db = database_at(L, list, i);
    if (db == NULL) {
      continue;
    }
    int trusted = 0;
    int found = load_from(L, db, name, i == count, &trusted);
    if (found == 1) {
      if (trusted && wrapper_raw(L, name)) {
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
  if (cosmic_surface_push_removed_library(L, name)) {
    /* cosmic.removed's words, as a refused compile of the same name says them. */
    lua_pushliteral(L, "\n\t");
    lua_insert(L, -2);
    lua_concat(L, 3);
  }
  return 1;
}

/* What a statement on a store connection may do: read. Every connection
 * the store searches is handed out as a borrowed handle
 * ([`store_databases`]), and a read-only open still leaves a connection
 * its own writable temp schema -- where a `CREATE TEMP TABLE modules`
 * would stand in front of the rows `require` loads -- and ATTACH.
 * Anything but a query is refused when it is prepared. FTS5, which the
 * catalog lookup uses, asks for data_version on its own. */
static int reads_only (void *unused, int action, const char *first,
                       const char *second, const char *database,
                       const char *trigger) {
  (void)unused;
  (void)database;
  (void)trigger;
  switch (action) {
    case SQLITE_SELECT:
    case SQLITE_READ:
    case SQLITE_FUNCTION:
    case SQLITE_RECURSIVE:
    return SQLITE_OK;
    case SQLITE_PRAGMA:
    return second == NULL && first != NULL &&
                   strcmp(first, "data_version") == 0
               ? SQLITE_OK
               : SQLITE_DENY;
    default:
    return SQLITE_DENY;
  }
}

static void release_database (void *db) { sqlite3_close_v2(db); }

/* Whether [`store_alone`] has set the attached databases aside: nothing is
 * attached until it puts them back, so its restore never grows the list. */
static int set_aside;

/* Opens another database and searches it ahead of every other, which is
 * what a project's own build database needs. The connection is held by a
 * guard until the list holds it: the message a failure copies out and the
 * list's growth both allocate, and an allocation can raise past the
 * close. SQLite hands back a connection even when it fails to open one,
 * and that one must be closed too. */
static int store_attach (lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  if (set_aside) {
    return luaL_error(L, "a database cannot be attached while the others are set aside");
  }
  struct cosmic_guard *guard = cosmic_guard_push(L, release_database);
  sqlite3 *db = NULL;
  /* Through the default VFS, as every connection [`cosmic.sqlite`] opens
   * is. No SQLITE_OPEN_URI, as there: `path` is a filename, so a `file:`
   * URI's `vfs=` never picks another VFS. */
  int rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, NULL);
  guard->resource = db;
  if (rc == SQLITE_OK) {
    rc = sqlite3_set_authorizer(db, reads_only, NULL);
  }
  if (rc == SQLITE_OK) {
    rc = cosmic_sqlite_functions(db);
  }
  if (rc != SQLITE_OK) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, db == NULL ? sqlite3_errstr(rc) : sqlite3_errmsg(db));
    return 2;
  }

  /* The one new slot is made first; every move after it is into a slot
   * that exists, which allocates nothing. */
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  lua_pushlightuserdata(L, db);
  lua_seti(L, list, count + 1);
  for (lua_Integer i = count; i >= 1; i--) {
    lua_geti(L, list, i);
    lua_seti(L, list, i + 1);
  }
  lua_pushlightuserdata(L, db);
  lua_seti(L, list, 1);
  guard->resource = NULL;

  return cosmic_done(L);
}

static void release_statement (void *stmt) { sqlite3_finalize(stmt); }

static void release_block (void *block) { cosmic_free(block); }

/* Pushes the one column `sql` answers for `key` in `db` and returns 1,
 * or pushes nothing and returns 0 when no row answers. The statement is
 * held by a guard while the value is copied out: the copy allocates,
 * and an allocation can raise past the finalize. */
static int lookup (lua_State *L, sqlite3 *db, const char *sql,
                   const char *key) {
  struct cosmic_guard *guard = cosmic_guard_push(L, release_statement);
  int slot = lua_gettop(L);
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
  guard->resource = stmt;
  if (rc != SQLITE_OK) {
    if (out_of_memory(rc)) return luaL_error(L, "not enough memory");
    die_unreadable(db);
  }
  sqlite3_bind_text(stmt, 1, key, -1, SQLITE_STATIC);
  rc = sqlite3_step(stmt);
  if (rc != SQLITE_ROW && rc != SQLITE_DONE) {
    if (out_of_memory(rc)) return luaL_error(L, "not enough memory");
    die_unreadable(db);
  }
  int found = rc == SQLITE_ROW;
  if (found) {
    /* The blob first, then its length; a NULL pointer with a length is
     * SQLite out of memory. */
    const void *value = sqlite3_column_blob(stmt, 0);
    int len = sqlite3_column_bytes(stmt, 0);
    if (value == NULL && len > 0) {
      return luaL_error(L, "not enough memory");
    }
    lua_pushlstring(L, value, (size_t)len);
  }
  /* Finalized now, and the emptied slot taken out from under the value. */
  lua_closeslot(L, slot);
  lua_remove(L, slot);
  return found;
}

/* Replaces the raw deflate stream on top of the stack, read from `db`,
 * with what it decodes to. Returns NULL, or why not with the stream left in
 * place. */
static const char *inflate_top (lua_State *L, sqlite3 *db) {
  int at = lua_gettop(L);
  size_t len;
  const char *stream = lua_tolstring(L, at, &len);
  struct cosmic_guard *guard = cosmic_guard_push(L, release_block);
  int slot = lua_gettop(L);
  unsigned char *text = NULL;
  size_t text_len = 0;
  const char *why = cosmic_inflate_raw(stream, len, inflate_limit(db), &text,
                                       &text_len);
  if (why != NULL) {
    lua_closeslot(L, slot);
    lua_remove(L, slot);
    return why;
  }
  guard->resource = text;
  lua_pushlstring(L, (const char *)text, text_len);
  lua_closeslot(L, slot);
  lua_remove(L, slot);
  lua_replace(L, at);
  return NULL;
}

/* One module's compiled bytes, for a caller that must load a chunk in
 * an environment of its own -- which is how the compiler runs
 * without the names the surface removed. The build stores it deflated
 * ([`build.writer`]), so it is inflated here. */
static int store_bytecode (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);

  static const char *query =
    "SELECT bytecode FROM main.modules WHERE path = ?1";
  for (lua_Integer i = 1; i <= count; i++) {
    sqlite3 *db = database_at(L, list, i);
    if (db != NULL && lookup(L, db, query, name)) {
      const char *why = inflate_top(L, db);
      if (why != NULL) {
        lua_pushnil(L);
        lua_pushfstring(L, "the bytecode of '%s': %s", name, why);
        return 2;
      }
      return cosmic_succeeded(L);
    }
  }
  lua_pushnil(L);
  lua_pushfstring(L, "no module '%s' in the store", name);
  return 2;
}

/* One module's Teal source, or a declaration's, from the database
 * attached to the running binary and no other: what a checker building
 * some other tree needs in order to type a `require` of this one's
 * modules. Only the binary's rows answer, so a project's own database
 * can never stand in for the standard library's types. The build stores
 * both deflated ([`build.writer`]), so each is inflated here. */
static int store_source (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  sqlite3 *db = binary_database(L, lua_upvalueindex(1));
  static const char *queries[] = {
    "SELECT source FROM main.decls WHERE path = ?1",
    "SELECT source FROM main.modules WHERE path = ?1",
  };
  for (size_t i = 0; db != NULL && i < sizeof queries / sizeof *queries; i++) {
    if (lookup(L, db, queries[i], name)) {
      const char *why = inflate_top(L, db);
      if (why != NULL) {
        lua_pushnil(L);
        lua_pushfstring(L, "the source of '%s' in the binary: %s", name, why);
        return 2;
      }
      return cosmic_succeeded(L);
    }
  }
  lua_pushnil(L);
  lua_pushfstring(L, "no module '%s' in the binary", name);
  return 2;
}

/* Pushes one database's meta value and returns 1, or pushes nothing and
 * returns 0 when that key has no row. */
static int database_meta (lua_State *L, sqlite3 *db, const char *key) {
  return lookup(L, db, "SELECT value FROM main.meta WHERE key = ?1", key);
}

static void big_endian_32 (unsigned char *out, uint32_t value) {
  out[0] = (unsigned char)(value >> 24);
  out[1] = (unsigned char)(value >> 16);
  out[2] = (unsigned char)(value >> 8);
  out[3] = (unsigned char)value;
}

static void big_endian_64 (unsigned char *out, uint64_t value) {
  for (unsigned i = 0; i < 8; i++)
    out[i] = (unsigned char)(value >> (56 - 8 * i));
}

static void push_hex (lua_State *L, const unsigned char *bytes, size_t length) {
  luaL_Buffer buffer;
  /* One more than the text for cosmic_hex's NUL, which the result leaves out. */
  char *text = luaL_buffinitsize(L, &buffer, length * 2 + 1);
  cosmic_hex(text, bytes, length);
  luaL_pushresultsize(&buffer, length * 2);
}

/* Portable runtime-v2 is an unambiguous, domain-separated encoding of the
 * validated physical core and the host-independent runtime basis:
 *
 *   "cosmic-runtime-v2" NUL, target:u32be, configuration:u32be,
 *   exact-raw-core-sha256[32], basis-length:u64be, basis bytes.
 */
static int push_portable_runtime (lua_State *L,
                                  const struct cosmic_artifact *artifact,
                                  int list) {
  sqlite3 *binary = binary_database(L, list);
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

static int push_binary_meta (lua_State *L, int list, const char *key) {
  sqlite3 *binary = binary_database(L, list);
  if (binary != NULL && database_meta(L, binary, key)) return 1;
  lua_pushnil(L);
  return 1;
}

/* Whether the artifact's selected core hashes to the digest its manifest
 * names, which is what a runtime identity is made of. A portable start checked
 * it before Lua ran; a host program is checked the first time it is asked.
 * The artifact is main's own, not a constant: the answer is remembered on it. */
static bool core_identity_holds (const struct cosmic_artifact *artifact) {
  return cosmic_artifact_core_matches((struct cosmic_artifact *)artifact);
}

/* One entry of metadata. Runtime values come only from the validated artifact
 * context and its own final database, never from a project database searched
 * ahead of it, and so does `ca_roots_default`, the roots its requests trust by
 * default (cosmic/http/init.tl's [`Http.default_roots`]), which a database
 * searched first must not widen. Other build metadata keeps ordinary database
 * search order. */
static int store_meta (lua_State *L) {
  const char *key = luaL_checkstring(L, 1);
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);

  lua_getfield(L, LUA_REGISTRYINDEX, STORE_ARTIFACT);
  const struct cosmic_artifact *artifact = lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (strcmp(key, "runtime_context") == 0) {
    if (artifact != NULL && artifact->fd >= 0 && artifact->split)
      lua_pushliteral(L, "database-v1");
    else if (artifact != NULL && artifact->fd >= 0 && artifact->host)
      lua_pushliteral(L, "host-v1");
    else if (artifact != NULL && artifact->fd >= 0)
      lua_pushliteral(L, "portable-v1");
    else
      lua_pushnil(L);
    return 1;
  }
  if (strcmp(key, "ca_roots_default") == 0) return push_binary_meta(L, list, key);
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

/* Calls the function at 1 with the arguments after it, searching only the
 * binary's own database, as a process that attached none would; then
 * puts every other back where it was, whether the call returned or
 * raised, and raises what it raised. What it returns is dropped: kept,
 * enough results would leave no free slot to put the list back with.
 * The list is only ever written in slots it already has -- nothing can
 * be attached meanwhile -- so putting them back allocates nothing. */
static int store_alone (lua_State *L) {
  luaL_checktype(L, 1, LUA_TFUNCTION);
  if (set_aside) {
    return luaL_error(L, "the attached databases are already set aside");
  }
  int list = lua_upvalueindex(1);
  int args = lua_gettop(L) - 1;
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  if (count > INT_MAX) {
    return luaL_error(L, "too many databases attached");
  }
  lua_createtable(L, (int)count, 0);
  for (lua_Integer i = 1; i <= count; i++) {
    lua_geti(L, list, i);
    lua_seti(L, -2, i);
  }
  lua_rotate(L, 1, 1); /* the saved list below the function */
  if (count > 1) {
    lua_geti(L, list, count);
    lua_seti(L, list, 1);
    for (lua_Integer i = count; i > 1; i--) {
      lua_pushnil(L);
      lua_seti(L, list, i);
    }
  }
  set_aside = 1;
  int status = lua_pcall(L, args, 0, 0);
  set_aside = 0;
  for (lua_Integer i = 1; i <= count; i++) {
    lua_geti(L, 1, i);
    lua_seti(L, list, i);
  }
  if (status != LUA_OK) {
    return lua_error(L);
  }
  return 0;
}

/* Every database `require` searches, in search order, each as a
 * borrowed [`cosmic.sqlite`] handle: what a verb that reads the shipped
 * tables -- `cosmic docs` over `docs` and `uses` -- queries, without a
 * path to any of them, since the binary's own is inside the binary.
 * The handles read only -- [`reads_only`] refuses anything but a query on
 * the store's connections, a temp table and ATTACH included; `close` on
 * one is a no-op, and the store keeps the connections for as long as
 * the process runs. */
static int store_databases (lua_State *L) {
  int list = lua_upvalueindex(1);
  lua_Integer count = (lua_Integer)lua_rawlen(L, list);
  lua_createtable(L, count > INT_MAX ? 0 : (int)count, 0);
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

/* Why a zone query failed, as nil and a message: `db`'s own error, or a
 * raise when it failed for memory. */
static int zones_failed (lua_State *L, sqlite3 *db, int rc) {
  if (out_of_memory(rc)) {
    return luaL_error(L, "not enough memory");
  }
  lua_pushnil(L);
  lua_pushfstring(L, "the binary's zones: %s", sqlite3_errmsg(db));
  return 2;
}

/* The names the binary's own `imports` table records the module `name`
 * requiring, as a list, sorted: none for a name it holds no row of. Nil
 * and why when the query failed: what walks the binary's module graph a
 * name at a time, where a handle ([`store_databases`]) would read every
 * module's rows. */
static int store_requires (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  sqlite3 *db = binary_database(L, lua_upvalueindex(1));
  if (db == NULL) {
    lua_pushnil(L);
    lua_pushliteral(L, "the running binary has no database");
    return 2;
  }
  struct cosmic_guard *guard = cosmic_guard_push(L, release_statement);
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(
      db, "SELECT requires FROM main.imports WHERE path = ?1 ORDER BY requires",
      -1, &stmt, NULL);
  guard->resource = stmt;
  if (rc != SQLITE_OK) {
    if (out_of_memory(rc)) return luaL_error(L, "not enough memory");
    die_unreadable(db);
  }
  sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);
  lua_newtable(L);
  lua_Integer n = 0;
  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    const char *required = (const char *)sqlite3_column_text(stmt, 0);
    if (required == NULL) {
      /* A NULL of a column declared NOT NULL is SQLite out of memory;
       * of any other, a row with nothing to name. */
      if (sqlite3_errcode(db) == SQLITE_NOMEM) {
        return luaL_error(L, "not enough memory");
      }
      continue;
    }
    lua_pushstring(L, required);
    lua_seti(L, -2, ++n);
  }
  if (rc != SQLITE_DONE) {
    if (out_of_memory(rc)) return luaL_error(L, "not enough memory");
    die_unreadable(db);
  }
  return cosmic_succeeded(L);
}

/* One time zone's TZif file, by IANA name, from the binary's own
 * database and no other: data the runtime's identity keys, read here
 * rather than through a handle, which would read every module's rows too. Nil and why when there is no such zone or
 * the query failed. */
static int store_zoneinfo (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  sqlite3 *db = binary_database(L, lua_upvalueindex(1));
  if (db == NULL) {
    lua_pushnil(L);
    lua_pushliteral(L, "the running binary has no database");
    return 2;
  }
  struct cosmic_guard *guard = cosmic_guard_push(L, release_statement);
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(db, "SELECT data FROM main.zoneinfo WHERE name = ?1",
                              -1, &stmt, NULL);
  guard->resource = stmt;
  if (rc == SQLITE_OK) {
    sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);
    rc = sqlite3_step(stmt);
  }
  if (rc == SQLITE_DONE) {
    lua_pushnil(L);
    lua_pushfstring(L, "the binary carries no zone %s", name);
    return 2;
  }
  if (rc != SQLITE_ROW) {
    return zones_failed(L, db, rc);
  }
  const void *data = sqlite3_column_blob(stmt, 0);
  int len = sqlite3_column_bytes(stmt, 0);
  if (data == NULL && len > 0) {
    return luaL_error(L, "not enough memory");
  }
  lua_pushlstring(L, data, (size_t)len);
  return cosmic_succeeded(L);
}

/* Every time zone name the binary's own database carries, as a set, or
 * nil and why when the query failed: as [`store_zoneinfo`], no handle. */
static int store_zone_names (lua_State *L) {
  sqlite3 *db = binary_database(L, lua_upvalueindex(1));
  if (db == NULL) {
    lua_pushnil(L);
    lua_pushliteral(L, "the running binary has no database");
    return 2;
  }
  struct cosmic_guard *guard = cosmic_guard_push(L, release_statement);
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(db, "SELECT name FROM main.zoneinfo", -1, &stmt,
                              NULL);
  guard->resource = stmt;
  if (rc != SQLITE_OK) {
    return zones_failed(L, db, rc);
  }
  lua_newtable(L);
  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    const char *zone = (const char *)sqlite3_column_text(stmt, 0);
    if (zone == NULL) {
      if (sqlite3_errcode(db) == SQLITE_NOMEM) {
        return luaL_error(L, "not enough memory");
      }
      continue;
    }
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, zone);
  }
  if (rc != SQLITE_DONE) {
    lua_pop(L, 1);
    return zones_failed(L, db, rc);
  }
  return cosmic_succeeded(L);
}

/* Private capability handed only to the trusted build.artifact chunk. */
static int store_trusted_prefix (lua_State *L) {
  const struct cosmic_artifact *artifact =
      lua_touserdata(L, lua_upvalueindex(1));
  if (artifact == NULL || artifact->fd < 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "no retained portable artifact");
    return 2;
  }
  if (artifact->host) {
    lua_pushnil(L);
    lua_pushliteral(L, "a host program or a core run against a database "
                       "carries only its own core, not the portable prefix "
                       "a portable program is made from");
    return 2;
  }
  uint64_t length = artifact->portable.prefix_length;
  if (length > (uint64_t)SIZE_MAX) {
    lua_pushnil(L);
    lua_pushliteral(L, "retained portable prefix is too large");
    return 2;
  }
  /* Startup binds the executing cached core to its manifest identity. Prefix
   * reuse has a stronger requirement: every stored range (core or decoder
   * stub, raw or compressed) will be copied into a future artifact, so verify
   * each against its stored digest before exposing any prefix bytes. This
   * stays lazy so an otherwise valid warm cached core can run commands that
   * do not reuse a corrupt artifact prefix. */
  for (uint32_t i = 0; i < artifact->portable.entry_count; i++) {
    const struct cosmic_portable_entry *entry = &artifact->portable.entries[i];
    if (!cosmic_sha256_range_matches(artifact->fd, entry->offset,
                                     entry->stored_length,
                                     entry->stored_sha256)) {
      lua_pushnil(L);
      lua_pushfstring(L,
                      "retained portable range %d digest differs from manifest",
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
  return cosmic_succeeded(L);
}

/* Reads the raw core a portable start is running into `into`, which holds
 * `entry->length` bytes: startup has already put it on disk and checked it,
 * and the artifact holds only its compressed range, which this does not
 * decode. The file is the running executable, reopened as
 * [`Proc.relaunch`] does, and must be a regular file of the manifest's
 * length. False when it cannot be read whole. */
static bool read_running_core (const struct cosmic_portable_entry *entry,
                               char *into) {
  int fd = cosmic_executable_fd();
  if (fd < 0) return false;
  struct stat st;
  bool read = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) &&
              st.st_size >= 0 && (uint64_t)st.st_size == entry->length &&
              cosmic_read_at(fd, into, (size_t)entry->length, 0);
  close(fd);
  return read;
}

/* Private capability handed only to the trusted build.artifact chunk: the
 * running core's exact bytes, checked against its manifest digest, and the
 * identity a host program made from them declares. A raw entry's bytes are
 * its range of the artifact; a compressed one is read from the cached core
 * the start is running, and hashed again, since the file may have changed
 * since startup hashed it. */
static int store_trusted_core (lua_State *L) {
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
  bool stored_raw = entry->codec == COSMIC_PORTABLE_CODEC_RAW;
  lua_createtable(L, 0, 4);
  luaL_Buffer buffer;
  char *bytes = luaL_buffinitsize(L, &buffer, (size_t)entry->length);
  if (stored_raw ? !cosmic_artifact_read(artifact, bytes, (size_t)entry->length,
                                         entry->offset)
                 : !read_running_core(entry, bytes)) {
    luaL_pushresultsize(&buffer, 0);
    lua_pop(L, 2);
    lua_pushnil(L);
    lua_pushliteral(L, "running core cannot be read");
    return 2;
  }
  if (!stored_raw) {
    unsigned char digest[COSMIC_DIGEST_MAX];
    size_t digest_length = 0;
    if (cosmic_digest("sha256", bytes, (size_t)entry->length, digest,
                      &digest_length) != 0 ||
        digest_length != COSMIC_PORTABLE_SHA256_LENGTH ||
        memcmp(digest, entry->sha256, COSMIC_PORTABLE_SHA256_LENGTH) != 0) {
      luaL_pushresultsize(&buffer, 0);
      lua_pop(L, 2);
      lua_pushnil(L);
      lua_pushliteral(L, "running core's digest differs from its manifest");
      return 2;
    }
  }
  luaL_pushresultsize(&buffer, (size_t)entry->length);
  lua_setfield(L, -2, "bytes");
  lua_pushinteger(L, (lua_Integer)entry->target_id);
  lua_setfield(L, -2, "target_id");
  lua_pushinteger(L, (lua_Integer)entry->configuration_id);
  lua_setfield(L, -2, "configuration_id");
  lua_pushlstring(L, (const char *)entry->sha256, COSMIC_PORTABLE_SHA256_LENGTH);
  lua_setfield(L, -2, "digest");
  return cosmic_succeeded(L);
}

/* The paths of the files the runtime holds open for the store, as a list:
 * each database the store searches, then its write-ahead log and its
 * shared-memory file, which SQLite opens beside it. These are the files
 * [`cosmic_store_holds_descriptor`] recognises, and no other: not the
 * artifact's descriptor, and no database kept in memory or as a
 * temporary file, which names none. */
static int store_paths (lua_State *L) {
  static const char *const suffixes[] = { "", "-wal", "-shm" };
  lua_newtable(L);
  lua_Integer next = 1;
  for (int index = 1; index <= cosmic_store_count(L); index++) {
    sqlite3 *db = cosmic_store_database(L, index);
    const char *name = db == NULL ? NULL : sqlite3_db_filename(db, "main");
    if (name == NULL || name[0] == '\0') continue;
    for (size_t part = 0; part < sizeof suffixes / sizeof suffixes[0]; part++) {
      lua_pushfstring(L, "%s%s", name, suffixes[part]);
      lua_rawseti(L, -2, next++);
    }
  }
  return 1;
}

static int open_store_module (lua_State *L,
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
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, store_alone, 1);
  lua_setfield(L, -2, "alone");
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, store_requires, 1);
  lua_setfield(L, -2, "requires");
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, store_zoneinfo, 1);
  lua_setfield(L, -2, "zoneinfo");
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, store_zone_names, 1);
  lua_setfield(L, -2, "zone_names");
  lua_pushcfunction(L, store_paths);
  lua_setfield(L, -2, "paths");
  lua_pushlightuserdata(L, (void *)artifact);
  lua_pushcclosure(L, store_trusted_prefix, 1);
  lua_setfield(L, -2, "trusted_prefix");
  lua_pushlightuserdata(L, (void *)artifact);
  lua_pushcclosure(L, store_trusted_core, 1);
  lua_setfield(L, -2, "trusted_core");
  lua_remove(L, -2);
  return 1;
}

int cosmic_store_count (lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, STORE_LIST);
  int count = (int)lua_rawlen(L, -1);
  lua_pop(L, 1);
  return count;
}

const struct cosmic_artifact *cosmic_store_artifact (lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, STORE_ARTIFACT);
  const struct cosmic_artifact *artifact = lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (artifact == NULL || artifact->fd < 0) return NULL;
  return artifact;
}

bool cosmic_store_holds_descriptor (lua_State *L, int fd) {
  const struct cosmic_artifact *artifact = cosmic_store_artifact(L);
  if (artifact != NULL && fd == artifact->fd) return true;
  struct stat held;
  int mode = fcntl(fd, F_GETFL);
  if (mode < 0 || fstat(fd, &held) != 0) return false;
  /* The store opens its databases SQLITE_OPEN_READONLY, so a descriptor on
   * the database or its log that can write is the program's own, and must
   * not pass as the runtime's: a write through it would change what the
   * store reads. A shared-memory file (-shm) is the exception: SQLite
   * opens it for writing whatever the database's mode, and it holds
   * locks, not content. */
  static const struct {
    const char *suffix;
    bool read_only;
  } parts[] = { { "", true }, { "-wal", true }, { "-shm", false } };
  bool reads_only = (mode & O_ACCMODE) == O_RDONLY;
  for (int index = 1; index <= cosmic_store_count(L); index++) {
    sqlite3 *db = cosmic_store_database(L, index);
    const char *name = db == NULL ? NULL : sqlite3_db_filename(db, "main");
    if (name == NULL || name[0] == '\0') continue;
    for (size_t part = 0; part < sizeof parts / sizeof parts[0]; part++) {
      if (parts[part].read_only && !reads_only) continue;
      char path[PATH_MAX];
      struct stat file;
      if (snprintf(path, sizeof path, "%s%s", name, parts[part].suffix) >= (int)sizeof path)
        continue;
      if (stat(path, &file) == 0 && file.st_dev == held.st_dev && file.st_ino == held.st_ino)
        return true;
    }
  }
  return false;
}

void cosmic_argfd (lua_State *L, int arg, lua_Integer fd) {
  const struct cosmic_artifact *artifact = cosmic_store_artifact(L);
  if (artifact != NULL && fd == (lua_Integer)artifact->fd)
    luaL_argerror(L, arg, "is this program's retained artifact descriptor, "
                          "through which every module it carries could be "
                          "read");
}

int cosmic_checkfd (lua_State *L, int arg) {
  int fd = cosmic_checkint(L, arg);
  cosmic_argfd(L, arg, fd);
  return fd;
}

sqlite3 *cosmic_store_database (lua_State *L, int index) {
  lua_getfield(L, LUA_REGISTRYINDEX, STORE_LIST);
  sqlite3 *db = database_at(L, -1, index);
  lua_pop(L, 1);
  return db;
}

void cosmic_store_install (lua_State *L, sqlite3 *binary,
                           const struct cosmic_artifact *artifact) {
  lua_newtable(L);
  if (binary != NULL) {
    sqlite3_set_authorizer(binary, reads_only, NULL);
    /* Without them a query of the binary's rows answers "no such
     * function", which is all a failure here costs. */
    (void)cosmic_sqlite_functions(binary);
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
}

void cosmic_store_set_raw (lua_State *L, const char *name) {
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

void cosmic_store_open_raw (lua_State *L) {
  for (size_t m = 0; m < RAW_VALUE_COUNT; m++) {
    if (raw_values[m].open == NULL) continue;
    raw_values[m].open(L);
    cosmic_store_set_raw(L, raw_values[m].raw);
  }
}

void cosmic_store_preload_raw (lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  for (size_t m = 0; m < RAW_VALUE_COUNT; m++) {
    if (!raw_value(L, raw_values[m].raw)) {
      continue; /* nothing registered under this name */
    }
    /* package.preload's own searcher calls its entry with its own fixed
     * "extra" (":preload:"), not caller-supplied data, so the raw value
     * has to be a closed-over constant. */
    lua_pushcclosure(L, return_upvalue, 1);
    lua_setfield(L, -2, raw_values[m].raw);
  }
  lua_pop(L, 1);
}

bool cosmic_store_meta (lua_State *L, const char *key, char *out, size_t size) {
  if (size == 0) {
    return false;
  }
  out[0] = '\0';
  lua_getfield(L, LUA_REGISTRYINDEX, STORE_LIST);
  lua_pushcclosure(L, store_meta, 1);
  lua_pushstring(L, key);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    lua_pop(L, 1);
    return false;
  }
  /* Copied while the value is still on the stack: once popped, nothing
   * keeps its string alive. */
  size_t length = 0;
  const char *value = lua_tolstring(L, -1, &length);
  int fits = value != NULL && length < size;
  if (fits) {
    memcpy(out, value, length + 1);
  }
  lua_pop(L, 1);
  return fits;
}
