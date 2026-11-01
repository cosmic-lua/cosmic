/*
 * SQLite at the Lua boundary. Values keep their type across it: a blob
 * comes back a blob and text comes back text, a parameter is bound by
 * an explicit call rather than guessed from a Lua value, and a handle
 * that has been closed fails the same way from every method.
 */

#ifndef COSMIC_SQLITE_H
#define COSMIC_SQLITE_H

#include <stdbool.h>

#include "lua.h"
#include "sqlite3.h"

/* Opens the table that backs the [`cosmic.sqlite`] wrapper, registered
 * under the raw [`cosmic.internal.sqlite`] name. */
int cosmic_open_sqlite (lua_State *L);

/* Pushes a handle over a connection something else owns: the store's
 * own databases, which Teal may read but never closes -- `close` on
 * such a handle is a no-op, and collection does not close it either.
 * [`cosmic_open_sqlite`] must have run on this state already, so the
 * handle's metatable exists. */
void cosmic_sqlite_push_borrowed (lua_State *L, sqlite3 *db);

/* Readies `db` as every handle this module opens is, so a connection
 * opened elsewhere (the store's) answers the same queries under the same
 * rules: turns PRAGMA trusted_schema off, so the views and triggers a
 * database file holds may call only what SQLite marks innocuous, and
 * registers `sha256`, `digest`, `hmac`, `deflate`, `inflate` and the
 * functions of the SQLite extensions the core is built with
 * (`generate_series`, `regexp`, `decimal`, `uuid`, `sha1`, `sha3`,
 * `base64`, `base85`, `compress`, ...). Forwards SQLite's status:
 * SQLITE_OK, or the first failure. */
int cosmic_sqlite_functions (sqlite3 *db);

/* Whether any of an SQL function's arguments is NULL, which the functions of
 * this module and of vector.h answer with NULL. */
static inline bool cosmic_any_null (int argc, sqlite3_value **argv) {
  for (int i = 0; i < argc; i++) {
    if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
      return true;
    }
  }
  return false;
}

#endif
