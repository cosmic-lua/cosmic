#include "sqlite.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/uio.h>

#include "check.h"
#include "compress.h"
#include "fail.h"
#include "guard.h"
#include "lauxlib.h"
#include "crypto.h"
#include "memory.h"
#include "process.h"
#include "sqlite3.h"
#include "vector.h"

#define HANDLE_TYPE "cosmic.sqlite.handle"
#define STATEMENT_TYPE "cosmic.sqlite.statement"
#define NULL_KEY "cosmic.sqlite.NULL"

/* How many databases a connection opened here may attach until it raises
 * the limit: SQLite's own default, well below the ceiling build.zig
 * compiles in (SQLITE_MAX_ATTACHED). */
#define ATTACHED_DEFAULT 10

/* How long a handle waits at another connection's lock until it is told
 * otherwise ([`handle_busy_timeout`]), in milliseconds. */
#define DEFAULT_WAIT_MS 60000

/* How many times this process has disowned its connections
 * ([`sqlite_disown`]). A handle is born of the count at its open, and is
 * disowned once the count has moved on. */
static unsigned disowned_times;

/* The most statements a handle keeps prepared for its SQL to run again
 * (`prepare_cached_result`, `release`). */
#define CACHED_STATEMENTS 16

/* A statement kept prepared, reset and with no bindings, under the SQL
 * it was prepared from, a copy the cache owns. */
struct cached {
  sqlite3_stmt *stmt;
  char *sql;
  size_t len;
};

struct handle {
  sqlite3 *db;
  /* Set when the connection belongs to someone else (the store): this
   * handle reads through it and never closes it. */
  int borrowed;
  unsigned born;
  int64_t busy_ms;
  int64_t deadline_ms;
  int64_t pause_ms;
  bool cancelled;
  /* What each call may run for, in milliseconds, -1 for no limit
   * ([`handle_time_limit`]), and the deadline of the call running, set
   * as it begins ([`begin_wait`]), -1 for none. */
  int64_t run_ms;
  int64_t run_deadline_ms;
  /* Why the progress handler stopped the call running: STOP_NONE, or the
   * time limit or a guard's caught signal. */
  int stop;
  /* The statements kept for their SQL to run again, the oldest first;
   * only a handle that owns its connection keeps any, and closing it
   * finalizes them first. */
  struct cached cache[CACHED_STATEMENTS];
  int cached;
  /* Set once [`handle_reads_only`] has held the handle to queries, and the
   * authorizer action it last refused, 0 for none. */
  bool reads_only;
  int denied;
  /* Set as a call that may park begins ([`begin_parkable_wait`]): its
   * caller is a coroutine that can yield, so the busy handler waits for
   * no lock (`parked` then set) and the Lua wrapper waits by
   * Clock.sleep, which parks a task of Poll.run, and runs it again. */
  bool parks;
  bool parked;
  /* The statement whose step parked at a lock and has not run since: a
   * task waits in it. Until it steps on, is rewound or is finalized, a
   * step of another statement that would start a run, and an exec, wait
   * their turn ([`turn_taken`]): run between the parked task's tries,
   * one would land inside its transaction, or it inside theirs. */
  struct statement *parked_on;
};

enum { STOP_NONE, STOP_TIME, STOP_SIGNAL, STOP_TURN };

/* How many virtual machine steps go between two looks at the clock: a
 * look is a vDSO read, small beside a thousand steps. */
#define PROGRESS_STEPS 1000

struct statement {
  sqlite3_stmt *stmt;
  sqlite3 *db;
  struct handle *owner;
  /* The SQL a cached prepare was asked for, which `release` keeps the
   * statement under; NULL for any other statement. The statement owns
   * it until `release` hands it to the cache. */
  char *sql;
  size_t len;
  /* Whether a step of this run has answered a row: a BUSY after one is
   * not parked, since the step run again would start the rows over. */
  bool rowed;
  /* Whether its BUSY may park: no PRAGMA, since a checkpoint (`PRAGMA
   * wal_checkpoint`) calls the busy handler and answers its row as busy
   * when the handler declines, with no BUSY to try again on. */
  bool parkable;
};

/* A budget belongs to one call, not one locking event: SQLite can ask
 * again with count zero for another statement in the same exec. The
 * clock is read only if the installed handler actually meets a lock. */
static void begin_wait (struct handle *h) {
  h->denied = 0;
  h->parks = false;
  h->parked = false;
  h->run_deadline_ms = h->run_ms < 0 ? -1 : cosmic_deadline_ms(h->run_ms);
  h->stop = STOP_NONE;
  if (h->busy_ms < 0) return;
  h->deadline_ms = -1;
  h->pause_ms = 1;
  h->cancelled = false;
}

/* As begin_wait, for a call whose BUSY the Lua wrapper waits out and
 * runs again itself: unless the argument at `blocks` is true, where `L`
 * can yield the busy handler holds the thread for nothing
 * ([`wait_busy`]). The wrapper asks this only where it can park the
 * caller, a task of Poll.run; another coroutine it runs again with
 * `blocks` true, and that call waits here as any other. */
static void begin_parkable_wait (lua_State *L, struct handle *h, int blocks) {
  begin_wait(h);
  h->parks = !lua_toboolean(L, blocks) && lua_isyieldable(L);
}

static int wait_busy (void *context, int previous) {
  (void)previous;
  struct handle *h = context;
  if (h->parks) {
    h->parked = true;
    return 0;
  }
  if (h->deadline_ms < 0) {
    h->deadline_ms = cosmic_deadline_ms(h->busy_ms);
  }
  int status = cosmic_paused(h->deadline_ms, &h->pause_ms);
  if (status == EINTR) h->cancelled = true;
  return status == 0;
}

/* Whether a call on `h` that starts a run must wait for the statement
 * parked on it (`parked_on` in struct handle); when it must, the call answers BUSY with
 * this reason ([`stopped_reason`]) and parks as `parks` says. */
static bool turn_taken (struct handle *h, const struct statement *s) {
  if (h->parked_on == NULL || h->parked_on == s) return false;
  h->stop = STOP_TURN;
  h->parked = h->parks;
  h->cancelled = false;
  return true;
}

/* After a step of `s` on `h`: it holds the turn where it parked, and
 * gives it back where it ran on. */
static void settle (struct handle *h, struct statement *s, int rc) {
  if ((rc & 0xff) == SQLITE_BUSY && h->parked) {
    h->parked_on = s;
  } else if (h->parked_on == s) {
    h->parked_on = NULL;
  }
}

/* `s` rewound or let go of: a turn it held is given back. */
static void unpark (struct statement *s) {
  if (s->owner != NULL && s->owner->parked_on == s) s->owner->parked_on = NULL;
}

/* SQLite's progress handler, installed by [`handle_time_limit`]: stops
 * the call running (SQLITE_INTERRUPT) once its time has passed, or once
 * a guard caught a signal, as a busy wait stops for one. */
static int progress (void *context) {
  struct handle *h = context;
  if (cosmic_signal_caught()) {
    h->stop = STOP_SIGNAL;
    return 1;
  }
  if (h->run_deadline_ms < 0) return 0;
  if (cosmic_wait_slice(h->run_deadline_ms) == 0) {
    h->stop = STOP_TIME;
    return 1;
  }
  return 0;
}

/* What a call the progress handler stopped failed for, in place of
 * SQLite's "interrupted", or NULL for any other failure. */
static const char *stopped_reason (const struct handle *h, int rc) {
  if (h != NULL && h->stop == STOP_TURN && (rc & 0xff) == SQLITE_BUSY)
    return "another task waits at a lock in a call on this handle; this call waits its turn";
  if (h == NULL || (rc & 0xff) != SQLITE_INTERRUPT) return NULL;
  if (h->stop == STOP_TIME) return "the call ran past its time limit (handle:time_limit)";
  if (h->stop == STOP_SIGNAL) return "the call was stopped by a signal the guard caught";
  return NULL;
}

/* A limit's compiled ceiling, which sqlite3_limit lowers a larger value
 * to without saying so. The limit is left as it was. */
static int limit_ceiling (sqlite3 *db, int id) {
  int old = sqlite3_limit(db, id, INT_MAX);
  return sqlite3_limit(db, id, old);
}

/* The PRAGMAs a handle held to queries may run: each only reads. Those of
 * the first list take no argument (one would set them); those of the
 * second name the table, index or count they read, or nothing. */
static const char *const bare_pragmas[] = {
  "application_id", "cell_size_check", "collation_list", "compile_options", "data_version",
  "database_list", "encoding", "foreign_keys", "freelist_count", "function_list",
  "journal_mode", "module_list", "page_count", "page_size", "pragma_list", "query_only",
  "schema_version", "user_version", NULL,
};
static const char *const reading_pragmas[] = {
  "foreign_key_check", "foreign_key_list", "index_info", "index_list", "index_xinfo",
  "integrity_check", "quick_check", "table_info", "table_list", "table_xinfo", NULL,
};

static bool listed (const char *const *list, const char *name) {
  for (int i = 0; list[i] != NULL; i++) {
    if (sqlite3_stricmp(list[i], name) == 0) return true;
  }
  return false;
}

/* Whether a PRAGMA's value sets a flag on, as SQLite reads one: a handle
 * held to queries may set query_only again, never take it off. */
static bool turns_on (const char *value) {
  return value != NULL && (sqlite3_stricmp(value, "1") == 0 || sqlite3_stricmp(value, "on") == 0 ||
                           sqlite3_stricmp(value, "true") == 0 || sqlite3_stricmp(value, "yes") == 0);
}

/* Whether `table` is named as an R*Tree's shadow tables are: SQLite's
 * R*Tree prepares its writes of them as it connects, for a SELECT too, so
 * a held handle lets those through the authorizer. Defensive mode refuses
 * a statement's own write to one, query_only refuses any write as it
 * runs, and the store's connections are read-only. */
static bool rtree_shadow (const char *table) {
  if (table == NULL) return false;
  size_t n = strlen(table);
  static const char *const suffixes[] = {"_node", "_rowid", "_parent"};
  for (size_t i = 0; i < sizeof suffixes / sizeof *suffixes; i++) {
    size_t k = strlen(suffixes[i]);
    if (n > k && sqlite3_stricmp(table + n - k, suffixes[i]) == 0) return true;
  }
  return false;
}

static int reads_only (void *denied, int action, const char *first,
                              const char *second, const char *database,
                              const char *trigger) {
  (void)trigger;
  bool temp = database != NULL && sqlite3_stricmp(database, "temp") == 0;
  switch (action) {
    case SQLITE_SELECT:
    case SQLITE_READ:
    case SQLITE_FUNCTION:
    case SQLITE_RECURSIVE:
    return SQLITE_OK;
    case SQLITE_PRAGMA:
    if (first != NULL && (listed(reading_pragmas, first) ||
                          (second == NULL && listed(bare_pragmas, first)) ||
                          (sqlite3_stricmp(first, "query_only") == 0 && turns_on(second))))
      return SQLITE_OK;
    break;
    case SQLITE_INSERT:
    case SQLITE_UPDATE:
    case SQLITE_DELETE:
    if (!temp && rtree_shadow(first)) return SQLITE_OK;
    break;
    default:
    break;
  }
  /* The first refusal names what the statement was. A CREATE of anything
   * temporary is asked first as an INSERT into the temp schema's table,
   * and never again once that is refused. */
  if (denied != NULL && *(int *)denied == 0)
    *(int *)denied = action == SQLITE_INSERT && temp ? SQLITE_CREATE_TEMP_TABLE : action;
  return SQLITE_DENY;
}

int cosmic_sqlite_hold_to_queries (sqlite3 *db, int *denied) {
  return sqlite3_set_authorizer(db, reads_only, denied);
}

/* What a handle held to queries refused, said after SQLite's "not
 * authorized". */
static const char *refused_what (int action) {
  switch (action) {
    case SQLITE_INSERT:
    case SQLITE_UPDATE:
    case SQLITE_DELETE: return "a write";
    case SQLITE_ATTACH: return "an ATTACH (VACUUM and VACUUM INTO attach one)";
    case SQLITE_DETACH: return "a DETACH";
    case SQLITE_PRAGMA: return "a PRAGMA that sets, or that is not one that reads";
    case SQLITE_TRANSACTION:
    case SQLITE_SAVEPOINT: return "a transaction";
    case SQLITE_CREATE_TEMP_TABLE:
    case SQLITE_CREATE_TEMP_INDEX:
    case SQLITE_CREATE_TEMP_TRIGGER:
    case SQLITE_CREATE_TEMP_VIEW:
    case SQLITE_CREATE_VTABLE: return "a temporary or virtual table";
    default: return "anything but a query";
  }
}

#define TOO_MANY_ATTACHED "too many attached databases"
#define HINT_SIZE 160

/* What SQLite's refusal of an ATTACH past the limit leaves unsaid: that
 * the limit is the connection's to raise, and how far. Empty for any
 * other reason, for a limit already at its ceiling, and for a limit of 0,
 * which a caller sets to refuse every ATTACH. */
static void attach_hint (sqlite3 *db, const char *reason, char hint[HINT_SIZE]) {
  hint[0] = '\0';
  if (strncmp(reason, TOO_MANY_ATTACHED, sizeof TOO_MANY_ATTACHED - 1) != 0) return;
  int limit = sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, -1);
  int ceiling = limit_ceiling(db, SQLITE_LIMIT_ATTACHED);
  if (limit == 0 || limit >= ceiling) return;
  snprintf(hint, HINT_SIZE, "; handle:limit(\"attached\", n) raises it, to at most %d",
           ceiling);
}

/* The reason the connection's last call failed, copied before anything
 * that allocates. */
static void push_reason (lua_State *L, sqlite3 *db) {
  char hint[HINT_SIZE];
  const char *reason = sqlite3_errmsg(db);
  attach_hint(db, reason, hint);
  lua_pushstring(L, reason);
  if (hint[0] != '\0') {
    lua_pushstring(L, hint);
    lua_concat(L, 2);
  }
}

/* A call's failure as a nil and its reason, the progress handler's own
 * where it stopped the call. */
static int stopped_or_failed (lua_State *L, const struct handle *h, sqlite3 *db, int rc);

static int failed (lua_State *L, sqlite3 *db, int rc) {
  lua_pushnil(L);
  if (db != NULL) {
    push_reason(L, db);
  } else {
    lua_pushstring(L, sqlite3_errstr(rc));
  }
  return 2;
}

static int failed_effect (lua_State *L, sqlite3 *db, int rc) {
  lua_pushboolean(L, 0);
  if (db != NULL) {
    push_reason(L, db);
  } else {
    lua_pushstring(L, sqlite3_errstr(rc));
  }
  return 2;
}

static void release_message (void *message) {
  cosmic_free(message);
}

struct outcome {
  int code;
  int extended;
  bool cancelled;
  bool timed_out;
  /* A BUSY the busy handler did not wait for: see `parks` in struct handle. */
  bool parked;
  struct cosmic_guard *message;
};

/* Copy before any Lua allocation: a finalizer can run another operation
 * on this connection, finalize a statement, or close the connection. */
static void capture (lua_State *L, struct outcome *out, sqlite3 *db, int rc,
                     struct handle *h) {
  out->code = rc & 0xff;
  out->extended = rc == SQLITE_OK || db == NULL ? rc : sqlite3_extended_errcode(db);
  out->cancelled = h != NULL && ((out->code == SQLITE_BUSY && h->cancelled) ||
                                 (out->code == SQLITE_INTERRUPT && h->stop == STOP_SIGNAL));
  out->timed_out = h != NULL && out->code == SQLITE_INTERRUPT && h->stop == STOP_TIME;
  out->parked = h != NULL && out->code == SQLITE_BUSY && h->parked;
  if (rc != SQLITE_OK) {
    const char *stopped = stopped_reason(h, rc);
    const char *reason = stopped != NULL ? stopped : db == NULL ? sqlite3_errstr(rc) : sqlite3_errmsg(db);
    char hint[HINT_SIZE] = "";
    if (db != NULL) attach_hint(db, reason, hint);
    if (h != NULL && h->reads_only && out->code == SQLITE_AUTH && h->denied != 0) {
      snprintf(hint, HINT_SIZE, "; this handle runs only queries (handle:reads_only), and refuses %s",
               refused_what(h->denied));
      h->denied = 0;
    }
    size_t length = strlen(reason);
    size_t size = length + strlen(hint) + 1;
    out->message->resource = cosmic_malloc(size);
    if (out->message->resource == NULL) {
      luaL_error(L, "not enough memory");
      return;
    }
    memcpy(out->message->resource, reason, length);
    memcpy((char *)out->message->resource + length, hint, size - length);
  }
}

static void push_outcome (lua_State *L, const struct outcome *out, bool payload) {
  lua_createtable(L, 0, payload ? 5 : 4);
  lua_pushinteger(L, out->code);
  lua_setfield(L, -2, "code");
  lua_pushinteger(L, out->extended);
  lua_setfield(L, -2, "extended_code");
  lua_pushstring(L, out->message->resource == NULL ? "" : out->message->resource);
  lua_setfield(L, -2, "reason");
  lua_pushboolean(L, out->cancelled);
  lua_setfield(L, -2, "cancelled");
  if (out->timed_out) {
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "timed_out");
  }
  if (out->parked) {
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "parked");
  }
}

/* Whether `h` holds a connection this process has disowned: one of its own,
 * opened before the last [`sqlite_disown`]. The store's connections, which
 * a borrowed handle reads through, are never disowned: the runtime itself
 * reads them, whatever a handle is told, read-only and from databases
 * nothing writes while the program runs, so a copy's reads take locks of
 * its own and find what the process's do. */
static bool disowned (const struct handle *h) {
  return h != NULL && !h->borrowed && h->born != disowned_times;
}

#define DISOWNED \
  "sqlite: this connection was opened before this process disowned its connections: a copy of a process opens its " \
  "own"

static struct handle *checked_handle (lua_State *L) {
  struct handle *h = luaL_checkudata(L, 1, HANDLE_TYPE);
  if (h->db == NULL) {
    luaL_error(L, "sqlite: the database handle is closed"); /* throws: a use after
                                                       close is a bug, not a
                                                       runtime failure */
  }
  if (disowned(h)) luaL_error(L, DISOWNED); /* throws: as above */
  return h;
}

static struct statement *checked_statement (lua_State *L) {
  struct statement *s = luaL_checkudata(L, 1, STATEMENT_TYPE);
  if (s->stmt == NULL) {
    luaL_error(L, "sqlite: the statement is closed"); /* throws: as above */
  }
  if (disowned(s->owner)) luaL_error(L, DISOWNED); /* throws: as above */
  return s;
}

/* The digest functions, registered on every handle this module opens,
 * so a build hashes inside the database it is writing rather than
 * round-tripping bytes out to Lua and back: `sha256(X)` is the 32-byte
 * digest of a text or blob; `digest(A, X)` the digest under the
 * algorithm named A; `hmac(A, K, X)` the HMAC of X under key K over
 * A. A NULL among the arguments gives NULL; an algorithm no one has
 * heard of is an error. */
static void finish_digest (sqlite3_context *ctx, int status,
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

/* A value's bytes, with an empty text or blob as a valid empty span
 * rather than a NULL pointer. */
static const void *bytes_of (sqlite3_value *value, size_t *len) {
  const void *data = sqlite3_value_blob(value);
  *len = (size_t)sqlite3_value_bytes(value);
  return data == NULL ? "" : data;
}

static void sha256_function (sqlite3_context *ctx, int argc,
                             sqlite3_value **argv) {
  if (cosmic_any_null(argc, argv)) {
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

static void digest_function (sqlite3_context *ctx, int argc,
                             sqlite3_value **argv) {
  if (cosmic_any_null(argc, argv)) {
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

static void hmac_function (sqlite3_context *ctx, int argc,
                           sqlite3_value **argv) {
  if (cosmic_any_null(argc, argv)) {
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

/* `deflate(X)` is the raw deflate of a text or blob, as
 * `Compress.deflate("raw", X)` writes it, and `inflate(X)` what such a
 * stream decodes to, as a blob, or an error when it is not one: how the
 * build stores text a reader rarely needs, and how a query reads it
 * back (`CAST(inflate(source) AS TEXT)`). A NULL argument gives NULL. The
 * result is copied out and freed here: SQLite must never free a block
 * of the core's own heap. */
static void deflate_function (sqlite3_context *ctx, int argc,
                              sqlite3_value **argv) {
  if (cosmic_any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  size_t len;
  const void *data = bytes_of(argv[0], &len);
  size_t out_len = 0;
  unsigned char *out = cosmic_deflate_raw(data, len, &out_len);
  if (out == NULL) {
    sqlite3_result_error_nomem(ctx);
    return;
  }
  sqlite3_result_blob64(ctx, out, out_len, SQLITE_TRANSIENT);
  cosmic_free(out);
}

/* Sets as the result what the raw deflate stream in the `len` bytes at
 * `data` decodes to, or why it does not. */
static void result_inflated (sqlite3_context *ctx, const void *data,
                             size_t len) {
  /* No more than SQLite would hold as one value anyway, so a stream
   * that decodes to more fails before it is ever all in memory. */
  int limit = sqlite3_limit(sqlite3_context_db_handle(ctx),
                            SQLITE_LIMIT_LENGTH, -1);
  unsigned char *out = NULL;
  size_t out_len = 0;
  const char *why = cosmic_inflate_raw(data, len, (size_t)limit, &out,
                                       &out_len);
  if (why != NULL) {
    sqlite3_result_error(ctx, why, -1);
    return;
  }
  sqlite3_result_blob64(ctx, out, out_len, SQLITE_TRANSIENT);
  cosmic_free(out);
}

static void inflate_function (sqlite3_context *ctx, int argc,
                              sqlite3_value **argv) {
  if (cosmic_any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  size_t len;
  const void *data = bytes_of(argv[0], &len);
  /* A deflate stream is never zero bytes. An empty value is most likely a
   * text a store carries without it (a pure test store), which a test
   * that reads it declares `store_text` for. */
  if (len == 0) {
    sqlite3_result_error(ctx, "inflate: the value is empty (a source a "
                         "store withholds, if it is one: a test that reads "
                         "it declares `Test.policy { store_text = true }`)", -1);
    return;
  }
  result_inflated(ctx, data, len);
}

/* `chunk(X)`: a module's bytecode as `string.dump` wrote it, whichever
 * way a build stored it: as it is, or raw-deflated. */
static void chunk_function (sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
  if (cosmic_any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  size_t len;
  const void *data = bytes_of(argv[0], &len);
  if (cosmic_stored_chunk(data, len)) {
    sqlite3_result_blob64(ctx, data, len, SQLITE_TRANSIENT);
    return;
  }
  if (len == 0) {
    sqlite3_result_error(ctx, "chunk: the value is empty", -1);
    return;
  }
  result_inflated(ctx, data, len);
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
  {"deflate", 1, deflate_function},
  {"inflate", 1, inflate_function},
  {"chunk", 1, chunk_function},
};

/* The entry points of SQLite's own extensions, from vendor/sqlite-ext/
 * and compiled into the core (build.zig). Each takes a connection, a
 * slot for an error message, and a loader's table, which a compiled-in
 * extension ignores. */
typedef int (*extension_init)(sqlite3 *, char **,
                              const sqlite3_api_routines *);
int sqlite3_basexx_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_compress_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_csv_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_decimal_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_ieee_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_regexp_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_series_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_sha_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_shathree_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_totype_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_uint_init (sqlite3 *, char **, const sqlite3_api_routines *);
int sqlite3_uuid_init (sqlite3 *, char **, const sqlite3_api_routines *);

static const extension_init extensions[] = {
  sqlite3_basexx_init, sqlite3_compress_init, sqlite3_csv_init,
  sqlite3_decimal_init,
  sqlite3_ieee_init, sqlite3_regexp_init, sqlite3_series_init,
  sqlite3_sha_init, sqlite3_shathree_init, sqlite3_totype_init,
  sqlite3_uint_init, sqlite3_uuid_init,
};

int cosmic_sqlite_functions (sqlite3 *db) {
  /* A database a caller opens is not trusted: its views and triggers may
   * call only what SQLite marks innocuous, never a pragma_* table such as
   * pragma_optimize, which runs ANALYZE. */
  int rc = sqlite3_db_config(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0,
                             (int *)NULL);
  /* Nor is the SQL a connection runs: in defensive mode, what ordinary SQL
   * could otherwise use to corrupt a file is refused (a write to
   * sqlite_schema, whatever PRAGMA writable_schema says, or to the shadow
   * tables of FTS5 and the R*Tree) or changes nothing (PRAGMA
   * journal_mode = OFF and schema_version = N). A handle opened with `defensive`
   * false ([`open_database`]) turns it off again. */
  if (rc == SQLITE_OK)
    rc = sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, (int *)NULL);
  for (size_t i = 0; rc == SQLITE_OK && i < sizeof functions / sizeof *functions;
       i++) {
    rc = sqlite3_create_function(
        db, functions[i].name, functions[i].arity,
        SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_DIRECTONLY, NULL,
        functions[i].call, NULL, NULL);
  }
  for (size_t i = 0;
       rc == SQLITE_OK && i < sizeof extensions / sizeof *extensions; i++) {
    char *trouble = NULL;
    rc = extensions[i](db, &trouble, NULL);
    sqlite3_free(trouble);
  }
  if (rc == SQLITE_OK) rc = cosmic_vector_functions(db);
  return rc;
}

/* The `file:` URI that names `path` and nothing more, with SQLite told
 * `immutable=1`: every byte but an unreserved one or a slash is
 * percent-escaped, so no `?`, `#` or `%` of the path is read as URI
 * syntax and no `vfs=`, `off=` or `len=` can be smuggled in. Leaves the
 * URI on the stack and returns it. */
static const char *immutable_uri (lua_State *L, const char *path,
                                  size_t path_len) {
  static const char hex[] = "0123456789ABCDEF";
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  luaL_addstring(&b, "file:");
  /* An absolute path takes the empty authority, so a leading "//" stays
   * part of the path. */
  if (path_len > 0 && path[0] == '/') {
    luaL_addstring(&b, "//");
  }
  for (size_t i = 0; i < path_len; i++) {
    unsigned char c = (unsigned char)path[i];
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
        c == '~' || c == '/') {
      luaL_addchar(&b, (char)c);
    } else {
      luaL_addchar(&b, '%');
      luaL_addchar(&b, hex[c >> 4]);
      luaL_addchar(&b, hex[c & 15]);
    }
  }
  luaL_addstring(&b, "?immutable=1");
  luaL_pushresult(&b);
  return lua_tostring(L, -1);
}

static int open_database (lua_State *L, bool result) {
  size_t path_len;
  const char *path = luaL_checklstring(L, 1, &path_len);
  int writable = lua_toboolean(L, 2);
  int immutable = lua_toboolean(L, 3);
  int create = lua_isnoneornil(L, 4) || lua_toboolean(L, 4);
  int defensive = lua_isnoneornil(L, 5) || lua_toboolean(L, 5);
  if (writable && immutable) {
    return luaL_error(L, "sqlite: a database cannot be both writable and immutable");
  }
  /* SQLite takes a C string: a NUL would silently open a shorter path. */
  if (memchr(path, '\0', path_len) != NULL) {
    if (result) return luaL_error(L, "sqlite: the path contains an embedded NUL byte");
    lua_pushnil(L);
    lua_pushstring(L, "the path contains an embedded NUL byte");
    return 2;
  }
  /* `path` is an ordinary filename, never a `file:` URI: SQLITE_OPEN_URI
   * is set only for the one URI this file builds itself, from an escaped
   * path and `immutable=1`, so `vfs=`, `off=` and `len=` are never parsed
   * out of a caller's path at all, not even refused. */
  int flags = writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY;
  if (writable && create) flags |= SQLITE_OPEN_CREATE;
  const char *name = path;
  if (immutable) {
    name = immutable_uri(L, path, path_len); /* stays on the stack */
    flags |= SQLITE_OPEN_URI;
  }

  struct outcome out = {0};
  if (result) out.message = cosmic_guard_push(L, release_message);
  struct handle *h = lua_newuserdatauv(L, sizeof *h, 0);
  int handle_index = lua_gettop(L);
  h->db = NULL;
  h->borrowed = 0;
  h->born = disowned_times;
  h->busy_ms = -1;
  h->deadline_ms = -1;
  h->pause_ms = 1;
  h->cancelled = false;
  h->run_ms = -1;
  h->run_deadline_ms = -1;
  h->stop = STOP_NONE;
  h->cached = 0;
  h->reads_only = false;
  h->denied = 0;
  h->parks = false;
  h->parked = false;
  h->parked_on = NULL;
  luaL_setmetatable(L, HANDLE_TYPE);

  /* The program's own file named through a descriptor of it
   * (/proc/self/fd/<n>) opens here, past cosmic.sys's `open` refusal
   * (core/syscalls_fs.c's `artifact_through_descriptor`): harmless, since
   * SQLite finds no database at the launcher's "#!" and refuses it
   * (SQLITE_NOTADB) without writing, and the database the program carries
   * lies past that header, where only core/vfs.c's offset reaches it.
   * TODO: refuse it here too, through the same check, if a portable
   * artifact ever begins with its database. */
  int rc = sqlite3_open_v2(name, &h->db, flags, NULL);
  /* Another process may hold the file's lock: two builds of one tree, or a
   * reader meeting a writer's commit. Wait for it rather than failing, as
   * [`handle_busy_timeout`] waits, so a guard's signal stops the wait. */
  if (rc == SQLITE_OK) {
    h->busy_ms = DEFAULT_WAIT_MS;
    rc = sqlite3_busy_handler(h->db, wait_busy, h);
  }
  if (rc == SQLITE_OK) sqlite3_limit(h->db, SQLITE_LIMIT_ATTACHED, ATTACHED_DEFAULT);
  if (rc == SQLITE_OK) rc = cosmic_sqlite_functions(h->db);
  if (rc == SQLITE_OK && !defensive)
    rc = sqlite3_db_config(h->db, SQLITE_DBCONFIG_DEFENSIVE, 0, (int *)NULL);
  if (result) {
    capture(L, &out, h->db, rc, NULL);
    if (rc != SQLITE_OK) {
      sqlite3_close_v2(h->db);
      h->db = NULL;
    }
    push_outcome(L, &out, rc == SQLITE_OK);
    if (rc == SQLITE_OK) {
      lua_pushvalue(L, handle_index);
      lua_setfield(L, -2, "handle");
    }
    return 1;
  }
  if (rc != SQLITE_OK) {
    int returns = failed(L, h->db, rc);
    sqlite3_close_v2(h->db);
    h->db = NULL;
    return returns;
  }
  return cosmic_succeeded(L);
}

static int sqlite_open (lua_State *L) {
  return open_database(L, false);
}

static int stopped_or_failed (lua_State *L, const struct handle *h, sqlite3 *db, int rc) {
  const char *reason = stopped_reason(h, rc);
  if (reason == NULL) return failed(L, db, rc);
  lua_pushnil(L);
  lua_pushstring(L, reason);
  return 2;
}

static int sqlite_open_result (lua_State *L) {
  return open_database(L, true);
}

/* Both surfaces execute each statement once. SQLite stops at the first
 * failure; preceding statements may already have changed the database. */
static int execute (struct handle *h, const char *sql) {
  begin_wait(h);
  return sqlite3_exec(h->db, sql, NULL, NULL, NULL);
}

static int handle_exec (lua_State *L) {
  struct handle *h = checked_handle(L);
  size_t len;
  const char *sql = luaL_checklstring(L, 2, &len);
  /* sqlite3_exec would stop at a NUL and skip the statements after it. */
  if (memchr(sql, '\0', len) != NULL) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "SQL contains an embedded NUL byte");
    return 2;
  }
  if (h->parked_on != NULL) {
    begin_wait(h);
    turn_taken(h, NULL);
    lua_pushboolean(L, 0);
    lua_pushstring(L, stopped_reason(h, SQLITE_BUSY));
    return 2;
  }
  /* No message of exec's own: it would be a copy of the connection's,
   * held in a local across the push that can raise. */
  int rc = execute(h, sql);
  if (rc != SQLITE_OK) {
    const char *stopped = stopped_reason(h, rc);
    if (stopped != NULL) {
      lua_pushboolean(L, 0);
      lua_pushstring(L, stopped);
      return 2;
    }
    return failed_effect(L, h->db, rc);
  }
  return cosmic_done(L);
}

static int handle_exec_result (lua_State *L) {
  size_t len;
  const char *sql = luaL_checklstring(L, 2, &len);
  if (memchr(sql, '\0', len) != NULL)
    return luaL_error(L, "sqlite: SQL contains an embedded NUL byte");
  struct outcome out = {0};
  out.message = cosmic_guard_push(L, release_message);
  struct handle *h = checked_handle(L);
  if (h->parked_on != NULL) {
    begin_wait(h);
    turn_taken(h, NULL);
    capture(L, &out, NULL, SQLITE_BUSY, h);
    push_outcome(L, &out, false);
    return 1;
  }
  int rc = execute(h, sql);
  capture(L, &out, h->db, rc, h);
  push_outcome(L, &out, false);
  return 1;
}

/* Stops each later exec or step that runs longer than timeout_ns,
 * rounded up to milliseconds, and any once a guard caught a signal; nil
 * takes the limit away, though a caught signal still stops a call. */
static int handle_time_limit (lua_State *L) {
  struct handle *h = checked_handle(L);
  lua_Integer ns = -1;
  if (!lua_isnoneornil(L, 2)) {
    ns = luaL_checkinteger(L, 2);
    if (ns < 0) return luaL_error(L, "sqlite: time_limit must be nonnegative, or nil for none");
  }
  /* The owner's connection outlives a borrowed wrapper, and SQLite has
   * no destructor for a progress handler's context. */
  if (h->borrowed)
    return luaL_error(L, "sqlite: cannot set time_limit on a borrowed handle");
  h->run_ms = ns < 0 ? -1 : ns / 1000000 + (ns % 1000000 != 0);
  h->run_deadline_ms = -1;
  h->stop = STOP_NONE;
  sqlite3_progress_handler(h->db, PROGRESS_STEPS, progress, h);
  return 0;
}

/* Holds the handle to queries for good: SQLite's authorizer refuses, as
 * each statement is prepared, anything but a SELECT, the functions it
 * calls and the PRAGMAs that read ([`reads_only`]), and VACUUM, through
 * the ATTACH it runs; and, a second wall each, `query_only` refuses a
 * write to any database as it runs, and no database may be attached.
 * The pragma runs before the authorizer that would refuse it. A borrowed handle's owner has its own rules. */
static void drop_cached (struct handle *h);

static int handle_reads_only (lua_State *L) {
  struct handle *h = checked_handle(L);
  if (h->borrowed)
    return luaL_error(L, "sqlite: cannot hold a borrowed handle to queries: its owner's rules hold it");
  if (h->reads_only) return cosmic_done(L);
  begin_wait(h);
  int rc = sqlite3_exec(h->db, "PRAGMA query_only = 1", NULL, NULL, NULL);
  if (rc != SQLITE_OK) return failed_effect(L, h->db, rc);
  sqlite3_limit(h->db, SQLITE_LIMIT_ATTACHED, 0);
  rc = cosmic_sqlite_hold_to_queries(h->db, &h->denied);
  if (rc != SQLITE_OK) return failed_effect(L, h->db, rc);
  /* A kept statement was prepared before the hold, past the authorizer:
   * each is prepared again under it. */
  drop_cached(h);
  h->reads_only = true;
  return cosmic_done(L);
}

static int handle_busy_timeout (lua_State *L) {
  lua_Integer ns = luaL_checkinteger(L, 2);
  if (ns < 0) return luaL_error(L, "sqlite: busy_timeout must be nonnegative");
  struct handle *h = checked_handle(L);
  /* The owner's connection outlives a borrowed wrapper, and SQLite
   * has no destructor for a busy handler's context. */
  if (h->borrowed)
    return luaL_error(L, "sqlite: cannot set busy_timeout on a borrowed handle");
  h->busy_ms = ns / 1000000 + (ns % 1000000 != 0);
  begin_wait(h);
  sqlite3_busy_handler(h->db, wait_busy, h);
  return 0;
}

/* Whether `h` keeps statements: it owns its connection, open and not
 * disowned. */
static bool keeps_statements (const struct handle *h) {
  return h->db != NULL && !h->borrowed && !disowned(h);
}

/* Finalizes every statement `h` keeps. */
static void drop_cached (struct handle *h) {
  for (int i = 0; i < h->cached; i++) {
    sqlite3_finalize(h->cache[i].stmt);
    cosmic_free(h->cache[i].sql);
  }
  h->cached = 0;
}

/* Frees the SQL of every statement a disowned `h` keeps, and not the
 * statements: they are the connection's, which the process this one is a
 * copy of still uses. */
static void forget_cached (struct handle *h) {
  for (int i = 0; i < h->cached; i++) cosmic_free(h->cache[i].sql);
  h->cached = 0;
}

/* Whether a statement of `sql` may be kept: not a PRAGMA, some of which
 * act as they are prepared (`busy_timeout`, `cache_size`), not as they
 * step. */
static bool keepable (const char *sql, size_t len) {
  size_t i = 0;
  while (i < len && (sql[i] == ' ' || sql[i] == '\t' || sql[i] == '\n' || sql[i] == '\r')) i++;
  return !(len - i >= 6 && sqlite3_strnicmp(sql + i, "pragma", 6) == 0);
}

/* The statement `h` keeps for `sql`, taken out of the cache with its copy
 * of the SQL (`*kept`); NULL when it keeps none. */
static sqlite3_stmt *take_cached (struct handle *h, const char *sql, size_t len, char **kept) {
  for (int i = h->cached - 1; i >= 0; i--) {
    struct cached *c = &h->cache[i];
    if (c->len == len && memcmp(c->sql, sql, len) == 0) {
      sqlite3_stmt *stmt = c->stmt;
      *kept = c->sql;
      memmove(c, c + 1, (size_t)(h->cached - i - 1) * sizeof *c);
      h->cached--;
      return stmt;
    }
  }
  return NULL;
}

/* Whether `sql` begins with the keyword PRAGMA, past spaces and
 * comments. */
static bool is_pragma (const char *sql, size_t len) {
  size_t i = 0;
  while (i < len) {
    if (isspace((unsigned char)sql[i])) {
      i++;
    } else if (i + 1 < len && sql[i] == '-' && sql[i + 1] == '-') {
      while (i < len && sql[i] != '\n') i++;
    } else if (i + 1 < len && sql[i] == '/' && sql[i + 1] == '*') {
      i += 2;
      while (i + 1 < len && !(sql[i] == '*' && sql[i + 1] == '/')) i++;
      i += 2;
    } else {
      break;
    }
  }
  if (i > len || len - i < 6 || sqlite3_strnicmp(sql + i, "pragma", 6) != 0) return false;
  return len - i == 6 || !(isalnum((unsigned char)sql[i + 6]) || sql[i + 6] == '_');
}

static int prepare_statement (lua_State *L, bool result, bool cached) {
  checked_handle(L);
  /* The argument `blocks` holds its place under what this pushes. */
  if (result) lua_settop(L, 3);
  size_t len;
  const char *sql = luaL_checklstring(L, 2, &len);
  if (len > INT_MAX) {
    if (result) return luaL_error(L, "sqlite: SQL is too long");
    lua_pushnil(L);
    lua_pushstring(L, "SQL is too long");
    return 2;
  }
  if (memchr(sql, '\0', len) != NULL) {
    if (result) return luaL_error(L, "sqlite: SQL contains an embedded NUL byte");
    lua_pushnil(L);
    lua_pushstring(L, "SQL contains an embedded NUL byte");
    return 2;
  }
  struct outcome out = {0};
  if (result) out.message = cosmic_guard_push(L, release_message);
  struct statement *s = lua_newuserdatauv(L, sizeof *s, 2);
  int statement_index = lua_gettop(L);
  s->stmt = NULL;
  s->db = NULL;
  s->owner = NULL;
  s->sql = NULL;
  s->len = 0;
  s->rowed = false;
  s->parkable = !is_pragma(sql, len);
  luaL_setmetatable(L, STATEMENT_TYPE);
  /* The statement holds a reference to its handle, so the handle cannot
   * be collected while a statement is still open on it. */
  lua_pushvalue(L, 1);
  lua_setiuservalue(L, -2, 1);
  struct handle *h = checked_handle(L);
  s->owner = h;
  s->db = h->db;
  if (result) {
    begin_parkable_wait(L, h, 3);
  } else {
    begin_wait(h);
  }
  /* A cached prepare keeps its SQL for `release`; the copy is made before
   * SQLite is asked, so a failure to make it leaves nothing prepared. */
  if (cached && keeps_statements(h) && keepable(sql, len)) {
    s->stmt = take_cached(h, sql, len, &s->sql);
    s->len = len;
    if (s->stmt != NULL) {
      /* Prepared before from this SQL, which held one statement then. */
      capture(L, &out, h->db, SQLITE_OK, NULL);
      push_outcome(L, &out, true);
      lua_pushvalue(L, statement_index);
      lua_setfield(L, -2, "statement");
      return 1;
    }
    s->sql = cosmic_malloc(len == 0 ? 1 : len);
    if (s->sql == NULL) return luaL_error(L, "sqlite: not enough memory");
    memcpy(s->sql, sql, len);
  }

  const char *tail = NULL;
  /* A statement the cache may keep is prepared PERSISTENT, so it does not
   * hold the connection's small lookaside pool for its long life. */
  int rc = sqlite3_prepare_v3(h->db, sql, (int)len,
                              s->sql != NULL ? SQLITE_PREPARE_PERSISTENT : 0,
                              &s->stmt, &tail);
  if (rc != SQLITE_OK) {
    if (!result) return failed(L, h->db, rc);
    capture(L, &out, h->db, rc, h);
    push_outcome(L, &out, false);
    return 1;
  }
  if (s->stmt == NULL) {
    if (result) return luaL_error(L, "sqlite: SQL contains no statement");
    lua_pushnil(L);
    lua_pushstring(L, "SQL contains no statement");
    return 2;
  }

  sqlite3_stmt *extra = NULL;
  const char *end = sql + len;
  rc = sqlite3_prepare_v2(h->db, tail, (int)(end - tail), &extra, NULL);
  if (rc != SQLITE_OK) {
    if (result) {
      capture(L, &out, h->db, rc, h);
      sqlite3_finalize(s->stmt);
      s->stmt = NULL;
      push_outcome(L, &out, false);
      return 1;
    }
    lua_pushnil(L);
    push_reason(L, h->db);
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
    return 2;
  }
  if (extra != NULL) {
    sqlite3_finalize(extra);
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
    if (result) return luaL_error(L, "sqlite: SQL contains more than one statement");
    lua_pushnil(L);
    lua_pushstring(L, "SQL contains more than one statement");
    return 2;
  }
  if (result) {
    capture(L, &out, h->db, SQLITE_OK, NULL);
    push_outcome(L, &out, true);
    lua_pushvalue(L, statement_index);
    lua_setfield(L, -2, "statement");
    return 1;
  }
  return cosmic_succeeded(L);
}

/* wait_ns(): how long a call on the handle waits at another
 * connection's lock, in nanoseconds, 0 for no wait: what the Lua wrapper
 * waits out where the busy handler did not ([`begin_parkable_wait`]). */
static int handle_wait_ns (lua_State *L) {
  struct handle *h = checked_handle(L);
  int64_t ms = h->borrowed || h->busy_ms < 0 ? 0 : h->busy_ms;
  lua_pushinteger(L, (lua_Integer)ms * 1000000);
  return 1;
}

static int handle_prepare (lua_State *L) {
  return prepare_statement(L, false, false);
}

static int handle_prepare_result (lua_State *L) {
  return prepare_statement(L, true, false);
}

/* prepare_cached_result(sql): as prepare_result, but the statement a
 * `release` of one prepared from the same SQL kept, when the handle keeps
 * one; a statement prepared this way goes back to the handle on
 * `release`. */
static int handle_prepare_cached_result (lua_State *L) {
  return prepare_statement(L, true, true);
}

static int handle_close (lua_State *L) {
  struct handle *h = luaL_checkudata(L, 1, HANDLE_TYPE);
  /* Closed already, borrowed or disowned: the connection is its owner's
   * to close, the store or the process this one is a copy of, and this
   * handle only lets go of it. */
  if (h->db == NULL || h->borrowed || disowned(h)) {
    forget_cached(h);
    h->db = NULL;
    return cosmic_done(L);
  }
  drop_cached(h);
  int rc = sqlite3_close(h->db);
  if (rc != SQLITE_OK) {
    return failed_effect(L, h->db, rc);
  }
  h->db = NULL;
  return cosmic_done(L);
}

static int handle_gc (lua_State *L) {
  struct handle *h = luaL_checkudata(L, 1, HANDLE_TYPE);
  if (h->db != NULL && !h->borrowed && !disowned(h)) {
    drop_cached(h);
    sqlite3_close_v2(h->db);
  }
  forget_cached(h);
  h->db = NULL;
  return 0;
}

/* A handle on a connection its owner -- the store -- opened and closes:
 * [`Store.databases()`] hands these out. */
void cosmic_sqlite_push_borrowed (lua_State *L, sqlite3 *db) {
  struct handle *h = lua_newuserdatauv(L, sizeof *h, 0);
  h->db = db;
  h->borrowed = 1;
  h->born = disowned_times;
  h->busy_ms = -1;
  h->deadline_ms = -1;
  h->pause_ms = 1;
  h->cancelled = false;
  h->run_ms = -1;
  h->run_deadline_ms = -1;
  h->stop = STOP_NONE;
  h->cached = 0;
  h->reads_only = false;
  h->denied = 0;
  h->parks = false;
  h->parked = false;
  h->parked_on = NULL;
  luaL_setmetatable(L, HANDLE_TYPE);
}

static int handle_changes (lua_State *L) {
  struct handle *h = checked_handle(L);
  lua_pushinteger(L, (lua_Integer)sqlite3_changes64(h->db));
  return 1;
}

static const struct {
  const char *name;
  int id;
} limit_names[] = {
  {"length", SQLITE_LIMIT_LENGTH},
  {"sql_length", SQLITE_LIMIT_SQL_LENGTH},
  {"column", SQLITE_LIMIT_COLUMN},
  {"expr_depth", SQLITE_LIMIT_EXPR_DEPTH},
  {"compound_select", SQLITE_LIMIT_COMPOUND_SELECT},
  {"vdbe_op", SQLITE_LIMIT_VDBE_OP},
  {"function_arg", SQLITE_LIMIT_FUNCTION_ARG},
  {"attached", SQLITE_LIMIT_ATTACHED},
  {"like_pattern_length", SQLITE_LIMIT_LIKE_PATTERN_LENGTH},
  {"variable_number", SQLITE_LIMIT_VARIABLE_NUMBER},
  {"trigger_depth", SQLITE_LIMIT_TRIGGER_DEPTH},
  {"worker_threads", SQLITE_LIMIT_WORKER_THREADS},
  {NULL, 0},
};

static int handle_limit (lua_State *L) {
  struct handle *h = checked_handle(L);
  const char *name = luaL_checkstring(L, 2);
  int value = cosmic_checkint(L, 3);
  for (int i = 0; limit_names[i].name != NULL; i++) {
    if (strcmp(name, limit_names[i].name) == 0) {
      int id = limit_names[i].id;
      if (h->reads_only && id == SQLITE_LIMIT_ATTACHED && value > 0)
        return luaL_error(L, "sqlite: a handle held to queries (handle:reads_only) attaches nothing");
      int old = sqlite3_limit(h->db, id, value);
      if (value >= 0 && sqlite3_limit(h->db, id, -1) < value) {
        int ceiling = sqlite3_limit(h->db, id, old);
        return luaL_error(L, "sqlite: the %s limit is at most %d, not %d", name,
                          ceiling, value); /* a bug, not a failure */
      }
      /* A statement takes the limits as it is prepared: those kept were
       * prepared under the old one. */
      if (value >= 0 && keeps_statements(h)) drop_cached(h);
      lua_pushinteger(L, old);
      return 1;
    }
  }
  return luaL_error(L, "sqlite: no such limit: %s", name); /* a bug, not a failure */
}

/* Whether a transaction is open on the connection: a BEGIN, or a SAVEPOINT
 * outside one, not yet committed or rolled back. */
static int handle_in_transaction (lua_State *L) {
  struct handle *h = checked_handle(L);
  lua_pushboolean(L, !sqlite3_get_autocommit(h->db));
  return 1;
}

/* Whether the connection's main database is read-only: opened so, or
 * on a file it may not write. */
static int handle_read_only (lua_State *L) {
  struct handle *h = checked_handle(L);
  lua_pushboolean(L, sqlite3_db_readonly(h->db, "main") == 1);
  return 1;
}

/* Copies the mode `PRAGMA journal_mode` yields into `context`, a
 * buffer of JOURNAL_MODE_SIZE. */
#define JOURNAL_MODE_SIZE 16
static int read_journal_mode (void *context, int columns, char **values, char **names) {
  (void)names;
  char *mode = context;
  if (columns > 0 && values[0] != NULL) snprintf(mode, JOURNAL_MODE_SIZE, "%s", values[0]);
  return 0;
}

/* Switches the main database to write-ahead mode, and returns the mode it
 * is in after, as the outcome's `mode`, and whether the database is a
 * temporary or memory one, as `temporary`. The switch needs the file to
 * itself for a moment, and SQLite can refuse it as busy without calling
 * the busy handler, so a busy refusal is tried again until the handle's
 * wait ([`handle_busy_timeout`]) has passed, or a guard caught a signal. */
static int handle_wal_result (lua_State *L) {
  struct outcome out = {0};
  out.message = cosmic_guard_push(L, release_message);
  struct handle *h = checked_handle(L);
  if (h->borrowed)
    return luaL_error(L, "sqlite: cannot set the journal mode of a borrowed handle: its owner sets it");
  char mode[JOURNAL_MODE_SIZE] = "";
  int64_t deadline = h->busy_ms < 0 ? -1 : cosmic_deadline_ms(h->busy_ms);
  int64_t pause = 1;
  int rc;
  /* One budget for the whole call: each try's busy handler waits only
   * until the call's deadline, and the time limit runs from the first. */
  begin_wait(h);
  for (;;) {
    h->deadline_ms = deadline;
    rc = sqlite3_exec(h->db, "PRAGMA main.journal_mode = WAL", read_journal_mode, mode, NULL);
    if ((rc & 0xff) != SQLITE_BUSY || h->cancelled || deadline < 0) break;
    int status = cosmic_paused(deadline, &pause);
    if (status == EINTR) h->cancelled = true;
    if (status != 0) break;
  }
  capture(L, &out, h->db, rc, h);
  /* A temporary or memory database has no file to keep a log beside: it
   * keeps the journal it has, which is no failure. */
  const char *file = sqlite3_db_filename(h->db, "main");
  bool temporary = file == NULL || file[0] == '\0';
  push_outcome(L, &out, true);
  lua_pushstring(L, mode);
  lua_setfield(L, -2, "mode");
  lua_pushboolean(L, temporary);
  lua_setfield(L, -2, "temporary");
  return 1;
}

static int handle_last_insert_rowid (lua_State *L) {
  struct handle *h = checked_handle(L);
  lua_pushinteger(L, (lua_Integer)sqlite3_last_insert_rowid(h->db));
  return 1;
}

static int bound (lua_State *L, int rc, sqlite3 *db) {
  if (rc != SQLITE_OK) {
    return failed_effect(L, db, rc);
  }
  return cosmic_done(L);
}

static int statement_parameters (lua_State *L) {
  struct statement *s = checked_statement(L);
  lua_pushinteger(L, sqlite3_bind_parameter_count(s->stmt));
  return 1;
}

static int statement_bind_null (lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = cosmic_checkint(L, 2);
  return bound(L, sqlite3_bind_null(s->stmt, index), s->db);
}

static int statement_bind_integer (lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = cosmic_checkint(L, 2);
  lua_Integer value = luaL_checkinteger(L, 3);
  return bound(L, sqlite3_bind_int64(s->stmt, index, (sqlite3_int64)value),
               s->db);
}

static int statement_bind_number (lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = cosmic_checkint(L, 2);
  lua_Number value = luaL_checknumber(L, 3);
  return bound(L, sqlite3_bind_double(s->stmt, index, (double)value), s->db);
}

static int statement_bind_text (lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = cosmic_checkint(L, 2);
  size_t len;
  const char *value = luaL_checklstring(L, 3, &len);
  return bound(L,
               sqlite3_bind_text64(s->stmt, index, value, (sqlite3_uint64)len,
                                   SQLITE_TRANSIENT, SQLITE_UTF8),
               s->db);
}

static int statement_bind_blob (lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = cosmic_checkint(L, 2);
  size_t len;
  const char *value = luaL_checklstring(L, 3, &len);
  return bound(L,
               sqlite3_bind_blob64(s->stmt, index, value, (sqlite3_uint64)len,
                                   SQLITE_TRANSIENT),
               s->db);
}

/* A Value's array for carray() is one of these kinds, past SQLite's own
 * value kinds, each 16 above the SQLITE_CARRAY_ type it binds as. */
#define ARRAY_KIND(type) (16 + (type))
#define ARRAY_TYPE(kind) ((kind) - 16)

/* The kind a Value field names, or SQLITE_NULL for none: an array's
 * field, as "integers", or SQLite's own. */
static int array_kind (const char *name, size_t size) {
  if (size == 8 && memcmp(name, "integers", 8) == 0) return ARRAY_KIND(SQLITE_CARRAY_INT64);
  if (size == 7 && memcmp(name, "numbers", 7) == 0) return ARRAY_KIND(SQLITE_CARRAY_DOUBLE);
  if (size == 5 && memcmp(name, "texts", 5) == 0) return ARRAY_KIND(SQLITE_CARRAY_TEXT);
  if (size == 5 && memcmp(name, "blobs", 5) == 0) return ARRAY_KIND(SQLITE_CARRAY_BLOB);
  return SQLITE_NULL;
}

/* Raises unless the list at `index` holds elements 1 to its length, each
 * of the array kind's type: an integer, a number, a string without a NUL
 * (carray reads a text to its first NUL), or a string. Returns its
 * length, which carray takes as an int. */
static int array_checked (lua_State *L, int index, int kind) {
  lua_Unsigned n = lua_rawlen(L, index);
  if (n > INT_MAX) luaL_error(L, "sqlite: an array Value holds more than %d elements", INT_MAX);
  for (lua_Unsigned i = 1; i <= n; i++) {
    lua_rawgeti(L, index, (lua_Integer)i);
    bool fits;
    switch (ARRAY_TYPE(kind)) {
      case SQLITE_CARRAY_INT64: fits = lua_isinteger(L, -1); break;
      case SQLITE_CARRAY_DOUBLE: fits = lua_type(L, -1) == LUA_TNUMBER; break;
      case SQLITE_CARRAY_TEXT: {
        size_t len;
        fits = lua_type(L, -1) == LUA_TSTRING;
        if (fits && strlen(lua_tolstring(L, -1, &len)) != len)
          luaL_error(L, "sqlite: element %d of a texts Value holds a NUL; bind it in blobs", (int)i);
        break;
      }
      default: fits = lua_type(L, -1) == LUA_TSTRING; break;
    }
    if (!fits)
      luaL_error(L, "sqlite: element %d of an array Value is not of its type", (int)i);
    lua_pop(L, 1);
  }
  return (int)n;
}

/* Binds the list at `index`, which array_checked has passed, for carray()
 * at parameter `param`. SQLite copies the elements, strings and all,
 * before this returns. An empty list binds a static empty array: the copy
 * would allocate 0 bytes, which SQLite treats as out of memory. */
static int bind_array (lua_State *L, sqlite3_stmt *stmt, int param, int index, int kind) {
  static sqlite3_int64 none;
  int n = array_checked(L, index, kind);
  int type = ARRAY_TYPE(kind);
  if (n == 0) return sqlite3_carray_bind_v2(stmt, param, &none, 0, type, SQLITE_STATIC, NULL);
  size_t each = type == SQLITE_CARRAY_INT64 ? sizeof(sqlite3_int64) :
                type == SQLITE_CARRAY_DOUBLE ? sizeof(double) :
                type == SQLITE_CARRAY_TEXT ? sizeof(char *) : sizeof(struct iovec);
  void *data = lua_newuserdatauv(L, each * (size_t)n, 0);
  for (int i = 0; i < n; i++) {
    lua_rawgeti(L, index, i + 1);
    switch (type) {
      case SQLITE_CARRAY_INT64: ((sqlite3_int64 *)data)[i] = lua_tointeger(L, -1); break;
      case SQLITE_CARRAY_DOUBLE: ((double *)data)[i] = lua_tonumber(L, -1); break;
      case SQLITE_CARRAY_TEXT: ((const char **)data)[i] = lua_tostring(L, -1); break;
      default: {
        size_t len;
        const char *bytes = lua_tolstring(L, -1, &len);
        ((struct iovec *)data)[i] = (struct iovec){ .iov_base = (void *)bytes, .iov_len = len };
        break;
      }
    }
    /* The string stays alive in the list, which the stack holds. */
    lua_pop(L, 1);
  }
  int rc = sqlite3_carray_bind_v2(stmt, param, data, n, type, SQLITE_TRANSIENT, NULL);
  lua_pop(L, 1);
  return rc;
}

/* Values are read raw: neither a metatable nor a coercion may run Lua
 * between checking this statement and binding its parameters. */
static int value_kind (lua_State *L, int index) {
  luaL_checktype(L, index, LUA_TTABLE);
  int kind = SQLITE_NULL;
  lua_pushnil(L);
  while (lua_next(L, index) != 0) {
    if (kind != SQLITE_NULL || lua_type(L, -2) != LUA_TSTRING)
      luaL_error(L, "sqlite: a Value has at most one named field");
    size_t size;
    const char *name = lua_tolstring(L, -2, &size);
    if (size == 7 && memcmp(name, "integer", 7) == 0 && lua_isinteger(L, -1)) kind = SQLITE_INTEGER;
    else if (size == 6 && memcmp(name, "number", 6) == 0 && lua_type(L, -1) == LUA_TNUMBER) kind = SQLITE_FLOAT;
    else if (size == 4 && memcmp(name, "text", 4) == 0 && lua_type(L, -1) == LUA_TSTRING) kind = SQLITE_TEXT;
    else if (size == 4 && memcmp(name, "blob", 4) == 0 && lua_type(L, -1) == LUA_TSTRING) kind = SQLITE_BLOB;
    else if (array_kind(name, size) != SQLITE_NULL && lua_type(L, -1) == LUA_TTABLE) {
      kind = array_kind(name, size);
      array_checked(L, lua_gettop(L), kind);
    }
    else luaL_error(L, "sqlite: a Value needs an integer, number, text or blob field of that type, "
                       "or an integers, numbers, texts or blobs list");
    lua_pop(L, 1);
  }
  return kind;
}

/* Binds the Value at stack `value`, of `kind` as value_kind found it,
 * to parameter `index`: SQLite's code. */
static int bind_value (lua_State *L, sqlite3_stmt *stmt, int index, int value, int kind) {
  if (kind == SQLITE_NULL) return sqlite3_bind_null(stmt, index);
  int rc;
  lua_pushnil(L);
  lua_next(L, value);
  if (kind >= ARRAY_KIND(0)) rc = bind_array(L, stmt, index, lua_gettop(L), kind);
  else if (kind == SQLITE_INTEGER) rc = sqlite3_bind_int64(stmt, index, lua_tointeger(L, -1));
  else if (kind == SQLITE_FLOAT) rc = sqlite3_bind_double(stmt, index, lua_tonumber(L, -1));
  else {
    size_t len;
    const char *bytes = lua_tolstring(L, -1, &len);
    rc = kind == SQLITE_TEXT ?
      sqlite3_bind_text64(stmt, index, bytes, (sqlite3_uint64)len, SQLITE_TRANSIENT, SQLITE_UTF8) :
      sqlite3_bind_blob64(stmt, index, bytes, (sqlite3_uint64)len, SQLITE_TRANSIENT);
  }
  lua_pop(L, 2);
  return rc;
}

static int statement_bind_values_result (lua_State *L) {
  luaL_checktype(L, 2, LUA_TTABLE);
  struct outcome out = {0};
  out.message = cosmic_guard_push(L, release_message);
  struct statement *s = checked_statement(L);
  int count = sqlite3_bind_parameter_count(s->stmt);
  lua_pushnil(L);
  while (lua_next(L, 2) != 0) {
    if (!lua_isinteger(L, -2) || lua_tointeger(L, -2) < 1 || lua_tointeger(L, -2) > count)
      return luaL_error(L, "sqlite: values must match the statement's parameter positions");
    lua_pop(L, 1);
  }
  /* Validate the whole list before changing any bindings. */
  for (int index = 1; index <= count; index++) {
    lua_rawgeti(L, 2, index);
    value_kind(L, lua_gettop(L));
    lua_pop(L, 1);
  }
  int rc = SQLITE_OK;
  for (int index = 1; index <= count; index++) {
    lua_rawgeti(L, 2, index);
    int kind = value_kind(L, lua_gettop(L));
    rc = bind_value(L, s->stmt, index, lua_gettop(L), kind);
    lua_pop(L, 1);
    if (rc != SQLITE_OK) break;
  }
  capture(L, &out, s->db, rc, NULL);
  push_outcome(L, &out, false);
  return 1;
}

/* kind_of(value, kind): value_kind run under lua_pcall by bind_all, its
 * result stored in the int `kind` points to, so that a
 * malformed Value is returned to bind_all's caller, which releases the
 * statement before it raises. */
static int kind_of (lua_State *L) {
  int *kind = lua_touserdata(L, 2);
  *kind = value_kind(L, 1);
  return 0;
}

/* Pushes bind_all's failure: the position (0 for the list as a whole),
 * why, and SQLite's code, or false for values of no shape a statement
 * takes, which the caller raises once it has released the statement. */
static int bind_failed (lua_State *L, int index, int code) {
  lua_pushinteger(L, index);
  lua_insert(L, -2);
  if (code == 0) lua_pushboolean(L, 0);
  else lua_pushinteger(L, code);
  return 3;
}

/* bind_all(values): binds values[1] to values[n] to the statement's n
 * parameters in one pass, each by its Lua type: an integer as an integer,
 * a float as a number, a string as text, a boolean as 1 or 0, and a table
 * as the Value its one field names ({} for NULL, {blob = s} for bytes, a
 * list for carray). Returns nothing where every value is bound, and
 * allocates nothing then unless a value is a Value table. Otherwise it
 * returns what bind_failed pushes; it raises only for a statement that
 * is gone or values that are no table. */
static int statement_bind_all (lua_State *L) {
  struct statement *s = checked_statement(L);
  luaL_checktype(L, 2, LUA_TTABLE);
  int count = sqlite3_bind_parameter_count(s->stmt);
  for (int index = 1; index <= count; index++) {
    int rc;
    int type = lua_rawgeti(L, 2, index);
    switch (type) {
      case LUA_TNUMBER:
      rc = lua_isinteger(L, -1) ? sqlite3_bind_int64(s->stmt, index, (sqlite3_int64)lua_tointeger(L, -1))
                                : sqlite3_bind_double(s->stmt, index, (double)lua_tonumber(L, -1));
      break;
      case LUA_TSTRING: {
        size_t len;
        const char *text = lua_tolstring(L, -1, &len);
        rc = sqlite3_bind_text64(s->stmt, index, text, (sqlite3_uint64)len, SQLITE_TRANSIENT, SQLITE_UTF8);
        break;
      }
      case LUA_TBOOLEAN:
      rc = sqlite3_bind_int64(s->stmt, index, lua_toboolean(L, -1) ? 1 : 0);
      break;
      case LUA_TTABLE: {
        int value = lua_gettop(L);
        /* value_kind reads raw fields, so a Value whose fields come
         * through __index would bind as NULL: refuse it, but for the
         * module's own read-only NULL. */
        if (lua_getmetatable(L, value)) {
          lua_pop(L, 1);
          lua_getfield(L, LUA_REGISTRYINDEX, NULL_KEY);
          int is_null = lua_rawequal(L, -1, value);
          lua_pop(L, 1);
          if (is_null) {
            rc = sqlite3_bind_null(s->stmt, index);
            break;
          }
          lua_pushliteral(L, " is a table with a metatable, which a Value is not: give a plain table");
          return bind_failed(L, index, 0);
        }
        lua_pushcfunction(L, kind_of);
        lua_pushvalue(L, value);
        int kind = SQLITE_NULL;
        lua_pushlightuserdata(L, &kind);
        if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
          const char *why = lua_tostring(L, -1);
          if (why == NULL) why = "a malformed Value";
          if (strncmp(why, "sqlite: ", 8) == 0) why += 8;
          lua_pushfstring(L, ": %s", why);
          return bind_failed(L, index, 0);
        }
        rc = bind_value(L, s->stmt, index, value, kind);
        break;
      }
      case LUA_TNIL:
      lua_pushliteral(L, " has no value (Sqlite.NULL binds NULL)");
      return bind_failed(L, index, SQLITE_RANGE);
      default:
      lua_pushfstring(L, " is a %s, which no parameter takes: give an integer, number, string, boolean or Value",
                      luaL_typename(L, -1));
      return bind_failed(L, index, 0);
    }
    lua_pop(L, 1);
    if (rc != SQLITE_OK) {
      lua_pushfstring(L, ": %s", sqlite3_errstr(rc));
      return bind_failed(L, index, rc & 0xff);
    }
  }
  /* Every position from 1 to count holds a value, so any other key is
   * one too many. A key that is no position at all raises, whatever else
   * the list holds; otherwise the highest position past the last
   * parameter is named, as RANGE. */
  lua_Integer highest = 0;
  lua_pushnil(L);
  while (lua_next(L, 2) != 0) {
    lua_pop(L, 1);
    if (!lua_isinteger(L, -1) || lua_tointeger(L, -1) < 1) {
      lua_pop(L, 1);
      lua_pushliteral(L, "values holds a key that is no parameter position from 1");
      return bind_failed(L, 0, 0);
    }
    if (lua_tointeger(L, -1) > count && lua_tointeger(L, -1) > highest) highest = lua_tointeger(L, -1);
  }
  if (highest > 0) {
    lua_pushfstring(L, "values holds a parameter %I, and the statement has %d", (LUAI_UACINT)highest, count);
    return bind_failed(L, 0, SQLITE_RANGE);
  }
  return 0;
}

/* wait_ns(): the statement's handle's wait_ns. */
static int statement_wait_ns (lua_State *L) {
  struct statement *s = checked_statement(L);
  const struct handle *h = s->owner;
  int64_t ms = h == NULL || h->borrowed || h->busy_ms < 0 ? 0 : h->busy_ms;
  lua_pushinteger(L, (lua_Integer)ms * 1000000);
  return 1;
}

/* The empty guard is cached across successful rows. Detach it before
 * allocating a failure record: a finalizer can re-enter this statement,
 * but must never reuse the guard that owns this call's captured message. */
static int statement_step_result (lua_State *L) {
  checked_statement(L);
  lua_settop(L, 2);
  lua_getiuservalue(L, 1, 2);
  bool marked = false;
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    cosmic_guard_push(L, release_message);
    marked = true;
    lua_pushvalue(L, -1);
    lua_setiuservalue(L, 1, 2);
  }
  int guard_index = lua_gettop(L);
  struct outcome out = {0};
  out.message = lua_touserdata(L, guard_index);
  struct statement *s = checked_statement(L);
  struct handle *h = s->owner;
  begin_parkable_wait(L, h, 2);
  if (s->rowed || !s->parkable) h->parks = false;
  /* A step on in a run's rows starts no transaction and waits for none. */
  bool waits = !s->rowed && turn_taken(h, s);
  int rc = SQLITE_BUSY;
  if (!waits) {
    rc = sqlite3_step(s->stmt);
    settle(h, s, rc);
    if (rc == SQLITE_ROW) {
      s->rowed = true;
    } else if (rc == SQLITE_DONE) {
      s->rowed = false;
    }
  }
  if (rc == SQLITE_ROW || rc == SQLITE_DONE) {
    lua_pushstring(L, rc == SQLITE_ROW ? "row" : "done");
    return 1;
  }
  capture(L, &out, waits ? NULL : s->db, rc, h);
  lua_pushnil(L);
  lua_setiuservalue(L, 1, 2);
  if (!marked) lua_toclose(L, guard_index);
  push_outcome(L, &out, false);
  return 1;
}

static int statement_step (lua_State *L) {
  struct statement *s = checked_statement(L);
  begin_wait(s->owner);
  int rc = sqlite3_step(s->stmt);
  if (rc == SQLITE_ROW) s->rowed = true;
  if (rc == SQLITE_DONE) s->rowed = false;
  if (rc == SQLITE_ROW) {
    lua_pushstring(L, "row");
    return cosmic_succeeded(L);
  }
  if (rc == SQLITE_DONE) {
    lua_pushstring(L, "done");
    return cosmic_succeeded(L);
  }
  return stopped_or_failed(L, s->owner, s->db, rc);
}

static int statement_columns (lua_State *L) {
  struct statement *s = checked_statement(L);
  lua_pushinteger(L, sqlite3_column_count(s->stmt));
  return 1;
}

/* The name of the column argument 2 counts from zero: its AS alias, or
 * what SQLite calls it without one. Known once the statement is
 * prepared, row or none. */
static int statement_name (lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = cosmic_checkint(L, 2);
  luaL_argcheck(L, index >= 0 && index < sqlite3_column_count(s->stmt), 2,
                "no such column in the statement");
  const char *name = sqlite3_column_name(s->stmt, index);
  if (name == NULL) {
    /* SQLite could not make the name: out of memory, not a value. */
    return luaL_error(L, "sqlite: not enough memory");
  }
  lua_pushstring(L, name);
  return 1;
}

/* The column argument 2 names, refused unless the statement is on a
 * row that has it. SQLite leaves a column read out of range, or read
 * when the last step did not return a row, undefined; sqlite3_data_count
 * is zero exactly then, so one check covers both. */
static int checked_column (lua_State *L, struct statement *s) {
  int index = cosmic_checkint(L, 2);
  luaL_argcheck(L, index >= 0 && index < sqlite3_data_count(s->stmt), 2,
                "no such column in the current row");
  return index;
}

static int statement_kind (lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = checked_column(L, s);
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

static int statement_integer (lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = checked_column(L, s);
  lua_pushinteger(L, (lua_Integer)sqlite3_column_int64(s->stmt, index));
  return 1;
}

static int statement_number (lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = checked_column(L, s);
  lua_pushnumber(L, (lua_Number)sqlite3_column_double(s->stmt, index));
  return 1;
}

/* Text and blob read the same bytes; they are two calls so the caller
 * says which it expects and a blob never arrives silently as text. */
static int statement_bytes (lua_State *L) {
  struct statement *s = checked_statement(L);
  int index = checked_column(L, s);
  const void *data = sqlite3_column_blob(s->stmt, index);
  int len = sqlite3_column_bytes(s->stmt, index);
  if (data == NULL && len > 0) {
    /* SQLite could not make the bytes: out of memory, not a value. */
    return luaL_error(L, "sqlite: not enough memory");
  }
  if (data == NULL) {
    lua_pushliteral(L, "");
  } else {
    lua_pushlstring(L, data, (size_t)len);
  }
  return 1;
}

/* Rewinds the statement; `clear` also drops every binding. SQLite's
 * sqlite3_reset reports the previous step's failure, and still rewinds. */
static int rewound (lua_State *L, int clear) {
  struct statement *s = checked_statement(L);
  begin_wait(s->owner);
  if (clear) {
    sqlite3_clear_bindings(s->stmt);
  }
  s->rowed = false;
  unpark(s);
  int rc = sqlite3_reset(s->stmt);
  if (rc != SQLITE_OK) {
    return failed_effect(L, s->db, rc);
  }
  return cosmic_done(L);
}

static int statement_reset (lua_State *L) {
  return rewound(L, 1);
}

/* reset_result(): as reset, but returns an ExecResult with SQLite's
 * codes, as step_result does: a statement stopped before its end, in
 * autocommit, commits at this reset, and a failure there (a deferred
 * foreign key, BUSY) is the statement's. */
static int statement_reset_result (lua_State *L) {
  struct outcome out = {0};
  out.message = cosmic_guard_push(L, release_message);
  struct statement *s = checked_statement(L);
  begin_wait(s->owner);
  sqlite3_clear_bindings(s->stmt);
  s->rowed = false;
  unpark(s);
  int rc = sqlite3_reset(s->stmt);
  capture(L, &out, s->db, rc, NULL);
  push_outcome(L, &out, false);
  return 1;
}

static int statement_rewind (lua_State *L) {
  return rewound(L, 0);
}

static int statement_finalize (lua_State *L) {
  struct statement *s = luaL_checkudata(L, 1, STATEMENT_TYPE);
  /* A disowned connection's statement is let go of as its handle is: to
   * finalize one that is writing would roll its statement back through
   * the descriptors the two processes share. */
  if (s->stmt != NULL) unpark(s);
  if (s->stmt != NULL && !disowned(s->owner)) {
    begin_wait(s->owner);
    sqlite3_finalize(s->stmt);
  }
  s->stmt = NULL;
  cosmic_free(s->sql);
  s->sql = NULL;
  return 0;
}

/* release(): done with the statement. One a cached prepare made goes
 * back to its handle, rewound and with its bindings cleared, for the
 * same SQL to take again, the oldest the handle keeps finalized to make
 * room; any other is finalized. Releasing one already released or
 * finalized does nothing. */
static int statement_release (lua_State *L) {
  struct statement *s = luaL_checkudata(L, 1, STATEMENT_TYPE);
  struct handle *h = s->owner;
  if (s->stmt == NULL || s->sql == NULL || h == NULL || h->db != s->db ||
      !keeps_statements(h)) {
    return statement_finalize(L);
  }
  begin_wait(h);
  /* The reset returns the last step's failure, which was reported then. */
  s->rowed = false;
  unpark(s);
  sqlite3_reset(s->stmt);
  sqlite3_clear_bindings(s->stmt);
  if (h->cached == CACHED_STATEMENTS) {
    sqlite3_finalize(h->cache[0].stmt);
    cosmic_free(h->cache[0].sql);
    memmove(&h->cache[0], &h->cache[1],
            (CACHED_STATEMENTS - 1) * sizeof h->cache[0]);
    h->cached--;
  }
  h->cache[h->cached].stmt = s->stmt;
  h->cache[h->cached].sql = s->sql;
  h->cache[h->cached].len = s->len;
  h->cached++;
  s->stmt = NULL;
  s->sql = NULL;
  return 0;
}

/* row(metatable, as_text?): the row the statement stands on as one
 * table, two slots a column: its kind ("integer", "number", "text",
 * "blob" or "null"), then its value (false for NULL); with `as_text`,
 * every column "text" and its bytes, NULL as "". The table takes
 * `metatable`. cosmic/sqlite.tl's rows read it. */
static int statement_row (lua_State *L) {
  struct statement *s = checked_statement(L);
  luaL_checktype(L, 2, LUA_TTABLE);
  bool as_text = lua_toboolean(L, 3);
  int columns = sqlite3_data_count(s->stmt);
  lua_createtable(L, 2 * columns, 0);
  for (int i = 0; i < columns; i++) {
    int type = as_text ? SQLITE_TEXT : sqlite3_column_type(s->stmt, i);
    switch (type) {
      case SQLITE_INTEGER:
      lua_pushliteral(L, "integer");
      lua_pushinteger(L, (lua_Integer)sqlite3_column_int64(s->stmt, i));
      break;
      case SQLITE_FLOAT:
      lua_pushliteral(L, "number");
      lua_pushnumber(L, (lua_Number)sqlite3_column_double(s->stmt, i));
      break;
      case SQLITE_TEXT:
      case SQLITE_BLOB: {
        if (type == SQLITE_TEXT) {
          lua_pushliteral(L, "text");
        } else {
          lua_pushliteral(L, "blob");
        }
        const void *data = sqlite3_column_blob(s->stmt, i);
        int len = sqlite3_column_bytes(s->stmt, i);
        if (data == NULL && len > 0) {
          /* SQLite could not make the bytes: out of memory, not a value. */
          return luaL_error(L, "sqlite: not enough memory");
        }
        if (data == NULL) {
          lua_pushliteral(L, "");
        } else {
          lua_pushlstring(L, data, (size_t)len);
        }
        break;
      }
      default:
      lua_pushliteral(L, "null");
      lua_pushboolean(L, 0);
      break;
    }
    lua_rawseti(L, -3, 2 * i + 2);
    lua_rawseti(L, -2, 2 * i + 1);
  }
  lua_pushvalue(L, 2);
  lua_setmetatable(L, -2);
  return 1;
}

/* Disowns every connection this process has open through this module:
 * each handle and statement opened before raises on any use after, and is
 * let go of without its connection being closed. */
static int sqlite_disown (lua_State *L) {
  (void)L;
  disowned_times++;
  return 0;
}

static const luaL_Reg handle_methods[] = {
  {"exec", handle_exec}, {"exec_result", handle_exec_result},     {"prepare", handle_prepare},
  {"close", handle_close},   {"changes", handle_changes},
  {"last_insert_rowid", handle_last_insert_rowid},
  {"limit", handle_limit},
  {"busy_timeout", handle_busy_timeout},
  {"wait_ns", handle_wait_ns},
  {"time_limit", handle_time_limit},
  {"reads_only", handle_reads_only},
  {"in_transaction", handle_in_transaction},
  {"read_only", handle_read_only},
  {"wal_result", handle_wal_result},
  {"prepare_result", handle_prepare_result},
  {"prepare_cached_result", handle_prepare_cached_result},
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
  {"step_result", statement_step_result},
  {"bind_values_result", statement_bind_values_result},
  {"bind_all", statement_bind_all},
  {"columns", statement_columns},
  {"name", statement_name},
  {"kind", statement_kind},
  {"integer", statement_integer},
  {"number", statement_number},
  {"bytes", statement_bytes},
  {"reset", statement_reset},
  {"reset_result", statement_reset_result},
  {"wait_ns", statement_wait_ns},
  {"rewind", statement_rewind},
  {"finalize", statement_finalize},
  {"release", statement_release},
  {"row", statement_row},
  {NULL, NULL},
};

static void make_type (lua_State *L, const char *name, const luaL_Reg *methods,
                       lua_CFunction collect) {
  luaL_newmetatable(L, name);
  lua_pushcfunction(L, collect);
  lua_setfield(L, -2, "__gc");
  lua_newtable(L);
  luaL_setfuncs(L, methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
}

static int null_written (lua_State *L) {
  return luaL_error(L, "sqlite: Sqlite.NULL is read-only");
}

/* Pushes the one read-only empty Value that binds NULL, kept in the
 * registry under NULL_KEY so bind_all knows it by identity. */
static void make_null (lua_State *L) {
  if (lua_getfield(L, LUA_REGISTRYINDEX, NULL_KEY) == LUA_TTABLE) return;
  lua_pop(L, 1);
  lua_newtable(L);
  lua_createtable(L, 0, 2);
  lua_pushcfunction(L, null_written);
  lua_setfield(L, -2, "__newindex");
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable");
  lua_setmetatable(L, -2);
  lua_pushvalue(L, -1);
  lua_setfield(L, LUA_REGISTRYINDEX, NULL_KEY);
}

/* number_text(x): `x` as SQLite writes a REAL as text, the way
 * vdbeMemRenderNum does at the default 17 digits ("%!.17g"): SQLite's own
 * rounding to 17 significant digits, with a ".0" where it would look
 * integral. cosmic never changes the digits a connection writes. */
static int sqlite_number_text (lua_State *L) {
  double x = (double)luaL_checknumber(L, 1);
  char buf[64];
  sqlite3_snprintf((int)sizeof buf, buf, "%!.17g", x);
  lua_pushstring(L, buf);
  return 1;
}

static const luaL_Reg module[] = {
  {"number_text", sqlite_number_text},
  {"open", sqlite_open},
  {"open_result", sqlite_open_result},
  {"disown", sqlite_disown},
  {NULL, NULL},
};

int cosmic_open_sqlite (lua_State *L) {
  sqlite3_initialize();
  make_type(L, HANDLE_TYPE, handle_methods, handle_gc);
  make_type(L, STATEMENT_TYPE, statement_methods, statement_finalize);
  luaL_newlib(L, module);
  lua_pushstring(L, sqlite3_libversion());
  lua_setfield(L, -2, "version");
  make_null(L);
  lua_setfield(L, -2, "NULL");
  return 1;
}
