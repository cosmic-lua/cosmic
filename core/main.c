/*
 * The entry. It finds the database attached to the running executable,
 * opens it through the offset VFS, and hands control to the `main`
 * module inside it. With no database attached it can bridge into Teal
 * from the tree instead, which is how the first binary gets built.
 */

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#include "boot.h"
#include "crypto.h"
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
  if (cosmic_vfs_register(path, at->offset, at->length) != SQLITE_OK) {
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

static bool is_stopword(const char *word, size_t len) {
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
static void catalog_query(const char *message, char *out, size_t outsz) {
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

/* How many of `message`'s significant (non-stopword) words appear
 * literally in `candidate`, case-insensitively -- a cheap confirmation
 * pass over the ONE row `catalog_guidance` already chose, not a second
 * search. FTS5's own ranking already prefers a row sharing more, or
 * rarer, words, but bm25 alone does not reliably separate a real match
 * from one accidental shared word (found by hand: an "io is not
 * available" message and the unrelated EMFILE row's "Too many open
 * files" share nothing meaningful except the word "files", and nothing
 * in `stopwords` catches an ordinary content word like that one). The
 * caller requires at least two before trusting the match. */
static int count_shared_words(const char *message, const char *candidate) {
  int shared = 0;
  const char *p = message;
  while (*p != '\0') {
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
    if (!is_stopword(start, len)) {
      for (const char *c = candidate; *c != '\0'; c++) {
        if (strncasecmp(c, start, len) == 0) {
          shared++;
          break;
        }
      }
    }
  }
  return shared;
}

/* The best-matching `catalog` row's guidance for `message`, or NULL
 * when `db` carries no catalog (a build/bridge run with no database
 * attached), nothing in it shares two or more significant words with
 * `message` (see `count_shared_words`), or the FTS5 query itself
 * carried no significant word at all. Read straight off the connection
 * `main` already has open for module lookups, through the same
 * `sqlite3_prepare_v2`/`step`/`column` shape `store.c` uses -- an
 * uncaught error is exactly the one path with no Lua state left in
 * working order to ask instead. */
static const char *catalog_guidance(sqlite3 *db, const char *message) {
  if (db == NULL || message == NULL || message[0] == '\0') {
    return NULL;
  }
  char query[1024];
  catalog_query(message, query, sizeof query);
  if (query[0] == '\0') {
    return NULL;
  }
  static char guidance[2048];
  char candidate[2048];
  sqlite3_stmt *stmt = NULL;
  const char *sql = "SELECT catalog.text, catalog.message FROM catalog_fts "
                     "JOIN catalog ON catalog.id = catalog_fts.rowid "
                     "WHERE catalog_fts MATCH ?1 "
                     "ORDER BY bm25(catalog_fts) LIMIT 1";
  if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
    return NULL;
  }
  sqlite3_bind_text(stmt, 1, query, -1, SQLITE_STATIC);
  const char *result = NULL;
  if (sqlite3_step(stmt) == SQLITE_ROW) {
    const unsigned char *text = sqlite3_column_text(stmt, 0);
    int len = sqlite3_column_bytes(stmt, 0);
    const unsigned char *msg = sqlite3_column_text(stmt, 1);
    int msg_len = sqlite3_column_bytes(stmt, 1);
    if (text != NULL && len > 0 && (size_t)len < sizeof guidance &&
        msg != NULL && msg_len > 0 && (size_t)msg_len < sizeof candidate) {
      memcpy(candidate, msg, (size_t)msg_len);
      candidate[msg_len] = '\0';
      if (count_shared_words(message, candidate) >= 2) {
        memcpy(guidance, text, (size_t)len);
        guidance[len] = '\0';
        result = guidance;
      }
    }
  }
  sqlite3_finalize(stmt);
  return result;
}

static int failed(lua_State *L, sqlite3 *db) {
  const char *message = lua_tostring(L, -1);
  fprintf(stderr, "cosmic: %s\n", message == NULL ? "failed" : message);
  const char *guidance = catalog_guidance(db, message);
  if (guidance != NULL) {
    fprintf(stderr, "cosmic: %s\n", guidance);
  }
  return 1;
}

/* Runs the main module the build recorded. The module is required like
 * any other, and what it returns is called with the command line as a
 * table whose slot 0 is the program's own name. `db` is threaded
 * through only for an uncaught failure's own catalog lookup. */
static int run_main(lua_State *L, sqlite3 *db, int argc, char **argv) {
  char main_name[256];
  const char *named = cosmic_store_meta(L, "main");
  if (named == NULL || named[0] == '\0') {
    return complain("the database names no main module", NULL);
  }
  snprintf(main_name, sizeof main_name, "%s", named);

  lua_getglobal(L, "require");
  lua_pushstring(L, main_name);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return failed(L, db);
  }
  if (!lua_isfunction(L, -1)) {
    return complain("the main module is not a function", main_name);
  }

  lua_newtable(L);
  for (int i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_seti(L, -2, i);
  }
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return failed(L, db);
  }
  return (int)luaL_optinteger(L, -1, 0);
}

int main(int argc, char **argv) {
  sqlite3_initialize();
  if (cosmic_crypto_init() != 0) {
    return complain("the crypto library would not start", NULL);
  }

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

  sqlite3 *db = NULL;
  if (found == 1) {
    db = open_attached(self, &attached);
    if (db == NULL) {
      lua_close(L);
      return complain("cannot open my own database", self);
    }
  }
  cosmic_store_install(L, db);
  cosmic_open_sqlite(L); /* leaves the module table on the stack */
  cosmic_store_set_raw(L, "cosmic.internal.sqlite");

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
      lua_close(L);
      return status;
    }
    lua_close(L);
    return complain("no database attached, and no tree to boot from", self);
  }

  int status = run_main(L, db, argc, argv);
  lua_close(L);
  sqlite3_close_v2(db);
  return status;
}
