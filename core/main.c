/*
 * The entry. A portable launch opens the database range from its retained
 * artifact descriptor. A raw core has no database and can only bridge into
 * Teal from a source tree through `--boot`.
 */

#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "boot.h"
#include "check.h"
#include "coverage.h"
#include "crypto.h"
#include "compress.h"
#include "lauxlib.h"
#include "executable.h"
#include "memory.h"
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

/* Answers what `cosmic.errors`'s `guidance` says beneath the uncaught
 * error at 1: the catalog's guidance for it, as lines to print, or
 * nothing. */
static int ask_guidance (lua_State *L) {
  lua_getglobal(L, "require");
  lua_pushliteral(L, "cosmic.errors");
  lua_call(L, 1, 1);
  lua_getfield(L, -1, "guidance");
  lua_pushvalue(L, 1);
  lua_call(L, 1, 1);
  return 1;
}

/* Prints the guidance `Errors.guidance` finds for the uncaught error on
 * top of the stack, the one policy of a report that is more than its
 * message and line, and leaves the stack as it was. The state is sound
 * after the failed call that raised it; anything that goes wrong asking
 * -- memory, a catalog that will not answer -- prints nothing more. */
static void print_guidance (lua_State *L) {
  int top = lua_gettop(L);
  if (!lua_checkstack(L, 2)) {
    return;
  }
  lua_pushcfunction(L, ask_guidance);
  lua_pushvalue(L, top);
  if (lua_pcall(L, 1, 1, 0) == LUA_OK && lua_type(L, -1) == LUA_TSTRING) {
    size_t len = 0;
    const char *text = lua_tolstring(L, -1, &len);
    fwrite(text, 1, len, stderr);
  }
  lua_settop(L, top);
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
    unsigned char *source = NULL;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
      owned = true;
      const char *file = (const char *)sqlite3_column_text(stmt, 0);
      /* The build stores source deflated (`build.writer`). A row that
       * will not inflate prints no line rather than a wrong one. */
      const void *stream = sqlite3_column_blob(stmt, 1);
      size_t stream_len = (size_t)sqlite3_column_bytes(stmt, 1);
      size_t source_len = 0;
      if (stream != NULL &&
          cosmic_inflate_raw(stream, stream_len, SIZE_MAX, &source,
                             &source_len) != NULL) {
        source = NULL;
      }
      const char *p = source == NULL ? "" : (const char *)source;
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
    cosmic_free(source);
    sqlite3_finalize(stmt);
    if (owned) {
      return found;
    }
  }
  return false;
}

/* An uncaught error: its message, then where in the Teal source it was
 * raised, then the guidance the catalog holds for it. */
static int failed (lua_State *L) {
  const char *message = lua_tostring(L, -1);
  fprintf(stderr, "cosmic: %s\n", message == NULL ? "failed" : message);
  source_position(L, message);
  if (message != NULL) {
    print_guidance(L);
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

/* Runs the main module the build recorded. */
static int run_main (lua_State *L, int argc, char **argv) {
  char main_name[256];
  if (!cosmic_store_meta(L, "main", main_name, sizeof main_name) ||
      main_name[0] == '\0') {
    return complain("the database names no main module", NULL);
  }

  struct entry entry = {main_name, argc, argv, 0};
  lua_pushcfunction(L, enter_main);
  lua_pushlightuserdata(L, &entry);
  if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
    return failed(L);
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
  cosmic_store_open_raw(L);
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_STORE_INSTALLED);

  if (db == NULL) {
    /* No database: the tree is the only source, so this is a build
     * machine bridging into Teal. A shipped binary never gets here, and
     * everything reachable here is the tree's own trusted source, so
     * every raw module goes straight in package.preload for the
     * bridge's searcher, which does not go through the store's trust
     * check -- the wrappers are ordinary tree modules the bridge
     * compiles from source, and each still `require`s its raw half,
     * under `cosmic.internal.`, by the same name a shipped binary
     * resolves through the trust-gated searcher instead. */
    cosmic_store_preload_raw(L);

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
  int status = run_main(L, argc, argv);
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_MAIN_RETURNED);
  cosmic_surface_close(L);
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_LUA_CLOSED);
  sqlite3_close_v2(db);
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_DATABASE_CLOSED);
  cosmic_artifact_close(&artifact);
  cosmic_startup_test_phase(startup, COSMIC_STARTUP_TEST_ARTIFACT_CLOSED);
  return status;
}
