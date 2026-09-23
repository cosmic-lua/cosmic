/*
 * The entry. A portable launch opens the database range from its retained
 * artifact descriptor. A raw core has no database and can only bridge into
 * Teal from a source tree through `--boot`.
 */

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "boot.h"
#include "check.h"
#include "coverage.h"
#include "crypto.h"
#include "lauxlib.h"
#include "executable.h"
#include "sqlite.h"
#include "sqlite3.h"
#include "store.h"
#include "startup.h"
#include "surface.h"
#include "vfs.h"

static int complain (const char *what, const char *detail) {
  if (detail == NULL) {
    fprintf(stderr, "cosmic: %s\n", what);
  } else {
    fprintf(stderr, "cosmic: %s: %s\n", what, detail);
  }
  return 2;
}

static sqlite3 *open_artifact (const char *path, int retained_fd,
                               int64_t offset, int64_t length) {
  if (cosmic_vfs_register(path, retained_fd, offset, length) !=
      SQLITE_OK) {
    return NULL;
  }
  char uri[8192];
  if (!cosmic_vfs_uri(uri, sizeof uri, path)) {
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

/* A word too common to mean anything on its own: matching one proves
 * nothing about two messages being related (a real report, found by
 * hand, of "not"/"are"/"and" alone coincidentally matching an unrelated
 * row's own short message -- "Not a directory" shares "not" with
 * anything that happens to say "is not available"). Deliberately short:
 * this is english function words cosmic's own messages actually use,
 * not a general-purpose stopword list. */
static const char *const stopwords[] = {
  "a",    "an",   "the",  "is",   "are",  "was",  "were", "be",
  "to",   "of",   "in",   "on",   "at",   "for",  "and",  "or",
  "not",  "no",   "this", "that", "it",   "its",  "as",   "by",
  "with", "from", "own",  NULL,
};

static bool is_stopword (const char *word, size_t len) {
  for (const char *const *s = stopwords; *s != NULL; s++) {
    if (strlen(*s) == len && strncasecmp(*s, word, len) == 0) {
      return true;
    }
  }
  return false;
}

/* `message`'s alphanumeric words, minus `stopwords`, as an FTS5 query
 * restricted to the `message` column and matching a `catalog` row
 * sharing any of them: `message: ("word1" OR "word2" OR ...)`, each
 * word double-quoted so it reads as an FTS5 string literal rather than
 * syntax -- a word built only from `isalnum` bytes can never itself
 * contain the quote that would need escaping. The column filter
 * matters: `catalog_fts` also indexes `text`, the guidance PROSE, and
 * an unfiltered query matches there too -- a real message merely
 * sharing an ordinary word with some unrelated row's own guidance
 * ("something", "path", ...) would otherwise surface that guidance for
 * an error it has nothing to do with. The catalog's own text is a
 * short, literal SUBSET of a real runtime message (a static prefix
 * ahead of whatever was interpolated in), so matching is this direction
 * -- the message's words against the catalog's indexed text -- rather
 * than a phrase match of the whole message, which the catalog's shorter
 * text could never satisfy. `bm25` ranks a catalog row sharing more, or
 * rarer, words above one sharing only a common word like "parameter". */
static void catalog_query (const char *message, char *out, size_t outsz) {
  size_t used = 0;
  int terms = 0;
  out[0] = '\0';
  if (outsz < 12) {
    return;
  }
  memcpy(out, "message: (", 10);
  used = 10;
  const char *p = message;
  while (*p != '\0' && terms < 16 && used + 4 < outsz) {
    while (*p != '\0' && !isalnum((unsigned char)*p)) {
      p++;
    }
    const char *start = p;
    while (isalnum((unsigned char)*p)) {
      p++;
    }
    size_t len = (size_t)(p - start);
    if (len == 0) {
      break;
    }
    if (is_stopword(start, len)) {
      continue;
    }
    size_t needed = len + 3 + (terms > 0 ? 4 : 0);
    if (used + needed + 1 >= outsz) {
      break;
    }
    if (terms > 0) {
      memcpy(out + used, " OR ", 4);
      used += 4;
    }
    out[used++] = '"';
    memcpy(out + used, start, len);
    used += len;
    out[used++] = '"';
    out[used] = '\0';
    terms++;
  }
  if (terms == 0) {
    out[0] = '\0';
  } else {
    out[used++] = ')';
    out[used] = '\0';
  }
}

/* The next alphanumeric word of `*at`, advancing past it: its start,
 * and its length in `*len`, 0 at the end of the text. */
static const char *next_word (const char **at, size_t *len) {
  const char *p = *at;
  while (*p != '\0' && !isalnum((unsigned char)*p)) {
    p++;
  }
  const char *start = p;
  while (isalnum((unsigned char)*p)) {
    p++;
  }
  *at = p;
  *len = (size_t)(p - start);
  return start;
}

/* Whether `text` holds `word` as a whole word, case-insensitively:
 * "os" is not in "cosmic", and "cosmic" is one word of "cosmic.time". */
static bool has_word (const char *text, const char *word, size_t len) {
  const char *at = text;
  for (;;) {
    size_t found_len = 0;
    const char *found = next_word(&at, &found_len);
    if (found_len == 0) {
      return false;
    }
    if (found_len == len && strncasecmp(found, word, len) == 0) {
      return true;
    }
  }
}

/* How many DISTINCT significant (non-stopword) words of `message`
 * appear as whole words in `candidate`, case-insensitively -- a cheap
 * confirmation pass over the ONE row `catalog_guidance` already chose,
 * not a second search. FTS5's own ranking already prefers a row sharing
 * more, or rarer, words, but bm25 alone does not reliably separate a
 * real match from one accidental shared word (found by hand: an "io is
 * not available" message and the unrelated EMFILE row's "Too many open
 * files" share nothing meaningful except the word "files", and nothing
 * in `stopwords` catches an ordinary content word like that one). The
 * caller requires at least two before trusting the match. Distinct and
 * whole, because one word said three times is still one word (found by
 * hand: "os is not available: time is cosmic.time, the environment is
 * cosmic.env, and processes are cosmic.proc" met the bar against a row
 * about "cosmic's own tree" on "cosmic" alone, counted per mention,
 * and on "os" found inside "cosmic"). */
static int count_shared_words (const char *message, const char *candidate) {
  int shared = 0;
  const char *at = message;
  for (;;) {
    size_t len = 0;
    const char *word = next_word(&at, &len);
    if (len == 0) {
      break;
    }
    if (is_stopword(word, len) || !has_word(candidate, word, len)) {
      continue;
    }
    /* Already counted, as an earlier word of the message? */
    bool seen = false;
    const char *before = message;
    for (;;) {
      size_t earlier_len = 0;
      const char *earlier = next_word(&before, &earlier_len);
      if (earlier == word || earlier_len == 0) {
        break;
      }
      if (earlier_len == len && strncasecmp(earlier, word, len) == 0) {
        seen = true;
        break;
      }
    }
    if (!seen) {
      shared++;
    }
  }
  return shared;
}

/* Prints `text` beneath an uncaught error, one `cosmic: ` line per
 * line of it, the first opening with `head` (`ENOENT (core/fail.h)`,
 * `Fs.read (cosmic/fs.tl:212)`) so a reader knows where the words come
 * from. Guidance is a doc comment's own lines, already wrapped; its
 * `@param`/`@return` lines describe the signature, not the failure,
 * and are left out here. */
static void print_guidance (const char *head, const char *text) {
  const char *p = text;
  bool first = true;
  while (*p != '\0') {
    const char *nl = strchr(p, '\n');
    size_t len = nl == NULL ? strlen(p) : (size_t)(nl - p);
    if (len > 0 && p[0] == '@') {
      /* a tag line: skip it */
    } else if (first) {
      fprintf(stderr, "cosmic: %s: %.*s\n", head, (int)len, p);
      first = false;
    } else {
      fprintf(stderr, "cosmic:   %.*s\n", (int)len, p);
    }
    p = nl == NULL ? p + len : nl + 1;
  }
}

/* The best-matching `catalog` row for `message` in `db`, printed as
 * guidance: true when one was, false when `db` carries no catalog (a
 * build/bridge run with no database attached), nothing in it shares
 * two or more significant words with `message` (see
 * `count_shared_words`), or the FTS5 query itself carried no
 * significant word at all. A row's own text is the hand-authored
 * guidance a seed row carries; an extracted row has none, and prints
 * the doc comment of the function it was found in instead, joined from
 * `docs` by symbol. Read straight off the connection, through the same
 * `sqlite3_prepare_v2`/`step`/`column` shape `store.c` uses -- an
 * uncaught error is exactly the one path with no Lua state left in
 * working order to ask instead. */
static bool catalog_guidance (sqlite3 *db, const char *message) {
  if (db == NULL || message == NULL || message[0] == '\0') {
    return false;
  }
  char query[1024];
  catalog_query(message, query, sizeof query);
  if (query[0] == '\0') {
    return false;
  }
  sqlite3_stmt *stmt = NULL;
  const char *sql =
      "SELECT coalesce(catalog.text, (SELECT d.text FROM main.docs d "
      "WHERE d.module = catalog.module AND "
      "d.source_symbol = catalog.symbol)), "
      "catalog.message, catalog.symbol, catalog.file, catalog.line "
      "FROM main.catalog_fts JOIN main.catalog "
      "ON catalog.id = catalog_fts.rowid "
      "WHERE catalog_fts MATCH ?1 ORDER BY bm25(catalog_fts) LIMIT 1";
  if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
    return false;
  }
  sqlite3_bind_text(stmt, 1, query, -1, SQLITE_STATIC);
  bool printed = false;
  if (sqlite3_step(stmt) == SQLITE_ROW) {
    const char *text = (const char *)sqlite3_column_text(stmt, 0);
    const char *candidate = (const char *)sqlite3_column_text(stmt, 1);
    const char *symbol = (const char *)sqlite3_column_text(stmt, 2);
    const char *file = (const char *)sqlite3_column_text(stmt, 3);
    int line = sqlite3_column_int(stmt, 4);
    if (text != NULL && text[0] != '\0' && candidate != NULL &&
        count_shared_words(message, candidate) >= 2) {
      char head[512];
      if (line > 0) {
        snprintf(head, sizeof head, "%s (%s:%d)", symbol == NULL ? "" : symbol,
                 file == NULL ? "" : file, line);
      } else {
        snprintf(head, sizeof head, "%s (%s)", symbol == NULL ? "" : symbol,
                 file == NULL ? "" : file);
      }
      print_guidance(head, text);
      printed = true;
    }
  }
  sqlite3_finalize(stmt);
  return printed;
}

/* Where an uncaught error's message says it was raised, as the source
 * it names: a Lua error message opens `chunk:line: `, and a module's
 * chunk name is its import path, so the line is one of that module's
 * own Teal lines -- tl's generated Lua keeps the line numbers of the
 * Teal it came from. Prints `cosmic: at <file>:<line>: <that line>`
 * from the first database in `db`'s search order that holds the module,
 * and says whether it did. */
static bool source_position (lua_State *L, const char *message) {
  if (message == NULL) {
    return false;
  }
  const char *colon = strchr(message, ':');
  if (colon == NULL || colon == message) {
    return false;
  }
  size_t name_len = (size_t)(colon - message);
  for (size_t i = 0; i < name_len; i++) {
    unsigned char c = (unsigned char)message[i];
    if (!isalnum(c) && c != '.' && c != '_' && c != '-') {
      return false;
    }
  }
  char *after = NULL;
  long line = strtol(colon + 1, &after, 10);
  if (after == colon + 1 || line <= 0 || *after != ':') {
    return false;
  }
  char name[256];
  if (name_len >= sizeof name) {
    return false;
  }
  memcpy(name, message, name_len);
  name[name_len] = '\0';

  int count = cosmic_store_count(L);
  for (int index = 1; index <= count; index++) {
    sqlite3 *db = cosmic_store_database(L, index);
    if (db == NULL) {
      continue;
    }
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT file, source FROM main.modules WHERE path = ?1";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
      continue;
    }
    sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);
    bool owned = false;
    bool found = false;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
      owned = true;
      const char *file = (const char *)sqlite3_column_text(stmt, 0);
      const char *source = (const char *)sqlite3_column_text(stmt, 1);
      const char *p = source == NULL ? "" : source;
      for (long at = 1; at < line && *p != '\0'; at++) {
        const char *nl = strchr(p, '\n');
        p = nl == NULL ? p + strlen(p) : nl + 1;
      }
      const char *nl = strchr(p, '\n');
      size_t len = nl == NULL ? strlen(p) : (size_t)(nl - p);
      while (len > 0 && (*p == ' ' || *p == '\t')) {
        p++;
        len--;
      }
      if (len > 0) {
        fprintf(stderr, "cosmic: at %s:%ld: %.*s\n", file == NULL ? name : file,
                line, (int)len, p);
        found = true;
      }
    }
    sqlite3_finalize(stmt);
    if (owned) {
      return found;
    }
  }
  return false;
}

/* An uncaught error: its message, then where in the Teal source it was
 * raised, then the guidance the first database in search order (a
 * project's own ahead of the binary's) holds for it. `db` is the
 * binary's own connection, the last one searched. */
static int failed (lua_State *L, sqlite3 *db) {
  const char *message = lua_tostring(L, -1);
  fprintf(stderr, "cosmic: %s\n", message == NULL ? "failed" : message);
  source_position(L, message);
  int count = cosmic_store_count(L);
  bool guided = false;
  for (int index = 1; index <= count && !guided; index++) {
    guided = catalog_guidance(cosmic_store_database(L, index), message);
  }
  if (!guided && count == 0) {
    catalog_guidance(db, message);
  }
  return 1;
}

/* What the entry hands the Lua side of running main, through one light
 * userdata, which pushing never allocates: everything it needs, and the
 * exit status it answers. */
struct entry {
  const char *main_name;
  int argc;
  char **argv;
  int status;
};

/* Requires the main module, calls what it returns with the command line
 * as a table whose slot 0 is the program's own name, and answers the
 * exit status it returned (`cosmic_tostatus`), refusing one that is
 * not. Every step here can raise -- building the command line on
 * memory, if on nothing else -- so it runs under lua_pcall, and a
 * raise is an uncaught error like any other. */
static int enter_main (lua_State *L) {
  struct entry *entry = lua_touserdata(L, 1);
  lua_getglobal(L, "require");
  lua_pushstring(L, entry->main_name);
  lua_call(L, 1, 1);
  if (!lua_isfunction(L, -1)) {
    entry->status =
        complain("the main module is not a function", entry->main_name);
    return 0;
  }

  lua_createtable(L, entry->argc, 1);
  for (int i = 0; i < entry->argc; i++) {
    lua_pushstring(L, entry->argv[i]);
    lua_seti(L, -2, i);
  }
  lua_call(L, 1, 1);
  int status = cosmic_tostatus(L, -1);
  if (status < 0) {
    complain("the main function returned no exit status from 0 to 255",
             entry->main_name);
    status = 2;
  }
  entry->status = status;
  return 0;
}

/* Runs the main module the build recorded. `db` is threaded through
 * only for an uncaught failure's own catalog lookup. */
static int run_main (lua_State *L, sqlite3 *db, int argc, char **argv) {
  char main_name[256];
  if (!cosmic_store_meta(L, "main", main_name, sizeof main_name) ||
      main_name[0] == '\0') {
    return complain("the database names no main module", NULL);
  }

  struct entry entry = {main_name, argc, argv, 0};
  lua_pushcfunction(L, enter_main);
  lua_pushlightuserdata(L, &entry);
  if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
    return failed(L, db);
  }
  return entry.status;
}

int cosmic_runtime_entry (const struct cosmic_startup *startup, int argc,
                          char **argv) {
  cosmic_coverage_prepare();
  const char *startup_trouble = cosmic_startup_validate(startup);
  if (startup_trouble != NULL) {
    return complain(startup_trouble, NULL);
  }

  sqlite3_initialize();
  if (cosmic_crypto_init() != 0) {
    return complain("the crypto library would not start", NULL);
  }

  struct cosmic_artifact artifact;
  const char *adoption_error = NULL;
  if (!cosmic_startup_adopt(startup, &artifact, &adoption_error)) {
    return complain(adoption_error == NULL ? "portable startup failed" :
                                              adoption_error,
                    NULL);
  }
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_ARTIFACT_ADOPTED);
  if (!cosmic_startup_test_pause(startup, &adoption_error)) {
    cosmic_artifact_close(&artifact);
    return complain(adoption_error, NULL);
  }
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_STARTUP_RELEASED);

  char self[4096];
  if (startup->kind != COSMIC_STARTUP_NATIVE) {
    if (snprintf(self, sizeof self, "%s", startup->artifact_path) >=
        (int)sizeof self) {
      cosmic_artifact_close(&artifact);
      return complain("artifact path is too long", NULL);
    }
  } else if (!cosmic_executable_path(self, sizeof self)) {
    cosmic_artifact_close(&artifact);
    return complain("cannot find my own path", NULL);
  }

  lua_State *L = cosmic_surface_open(self);
  if (L == NULL) {
    cosmic_artifact_close(&artifact);
    return complain("no memory for a Lua state", NULL);
  }

  sqlite3 *db = NULL;
  if (startup->kind != COSMIC_STARTUP_NATIVE) {
    db = open_artifact(self, artifact.fd,
                       (int64_t)artifact.portable.database_offset,
                       (int64_t)artifact.portable.database_length);
    if (db == NULL) {
      cosmic_surface_close(L);
      cosmic_artifact_close(&artifact);
      return complain("cannot open my own database", self);
    }
    cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_DATABASE_OPENED);
  }
  cosmic_store_install(L, db,
                       startup->kind != COSMIC_STARTUP_NATIVE ? &artifact : NULL);
  cosmic_open_sqlite(L); /* leaves the module table on the stack */
  cosmic_store_set_raw(L, "cosmic.internal.sqlite");
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_STORE_INSTALLED);

  if (db == NULL) {
    /* No database: the tree is the only source, so this is a build
     * machine bridging into Teal. A shipped binary never gets here, and
     * everything reachable here is the tree's own trusted source, so
     * every raw module goes straight in package.preload for the
     * bridge's searcher, which does not go through the store's trust
     * check -- `cosmic.store`, `cosmic.sqlite`, and `cosmic.coverage`
     * are ordinary tree modules the bridge compiles from source, and
     * each still `require`s its raw half, under `cosmic.internal.`, by
     * the same name a shipped binary resolves through the trust-gated
     * searcher instead. */
    lua_getfield(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    lua_pushcfunction(L, cosmic_open_sqlite);
    lua_setfield(L, -2, "cosmic.internal.sqlite");
    lua_pop(L, 1);
    cosmic_store_preload_raw(L, "cosmic.internal.store");
    cosmic_store_preload_raw(L, "cosmic.internal.debug");

    if (argc >= 5 && strcmp(argv[1], "--boot") == 0) {
      int status = cosmic_boot(L, argv[2], argv[3], argc, argv);
      cosmic_surface_close(L);
      cosmic_artifact_close(&artifact);
      return status;
    }
    cosmic_surface_close(L);
    cosmic_artifact_close(&artifact);
    return complain("no database attached, and no tree to boot from", self);
  }

  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_MAIN_ENTERING);
  int status = run_main(L, db, argc, argv);
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_MAIN_RETURNED);
  cosmic_surface_close(L);
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_LUA_CLOSED);
  sqlite3_close_v2(db);
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_DATABASE_CLOSED);
  cosmic_artifact_close(&artifact);
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_ARTIFACT_CLOSED);
  return status;
}
