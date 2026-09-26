/*
 * SQLite at the Lua boundary. Values keep their type across it: a blob
 * comes back a blob and text comes back text, a parameter is bound by
 * an explicit call rather than guessed from a Lua value, and a handle
 * that has been closed fails the same way from every method.
 */

#ifndef COSMIC_SQLITE_H
#define COSMIC_SQLITE_H

#include "lua.h"
#include "sqlite3.h"

/* Opens the table that backs the `cosmic.sqlite` wrapper, registered
 * under the raw `cosmic.internal.sqlite` name. */
int cosmic_open_sqlite (lua_State *L);

/* The VFS every connection `cosmic.sqlite` opens goes through, and the
 * store's `attach` too: the default one, but that each file it opens or
 * asks after is recorded while `observe` has recording on, for
 * build.filesystem_observations to key a test by. `cosmic_open_sqlite`
 * registers it, which the store's `cosmic_store_open_raw` runs at
 * startup, before any Lua can ask for a database. */
#define COSMIC_SQLITE_OBSERVED_VFS "cosmic-observed"

/* Pushes a handle over a connection something else owns: the store's
 * own databases, which Teal may read but never closes -- `close` on
 * such a handle is a no-op, and collection does not close it either.
 * `cosmic_open_sqlite` must have run on this state already, so the
 * handle's metatable exists. */
void cosmic_sqlite_push_borrowed (lua_State *L, sqlite3 *db);

/* Registers the functions every handle this module opens knows --
 * `sha256`, `digest`, `hmac`, `deflate`, `inflate` -- on `db`, so a
 * connection opened elsewhere (the store's) answers the same queries.
 * Forwards SQLite's status: SQLITE_OK, or the first failure. */
int cosmic_sqlite_functions (sqlite3 *db);

#endif
