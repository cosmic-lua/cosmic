/*
 * SQLite at the Lua boundary. Values keep their type across it: a blob
 * comes back a blob and text comes back text, a parameter is bound by
 * an explicit call rather than guessed from a Lua value, and a handle
 * that has been closed fails the same way from every method.
 */

#ifndef COSMIC_SQLITE_H
#define COSMIC_SQLITE_H

#include "lua.h"

/* Opens the table that backs the `cosmic.sqlite` wrapper, registered
 * under the raw `cosmic.internal.sqlite` name. */
int cosmic_open_sqlite(lua_State *L);

#endif
