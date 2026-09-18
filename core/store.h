/*
 * The module store. `require` reads a database and nothing else: a `.tl`
 * on disk is input to the build, never to the runtime.
 *
 * More than one database can be in play. A project's own build database
 * is searched ahead of the one attached to the binary, which is how the
 * tool builds and runs a tree other than its own.
 */

#ifndef COSMIC_STORE_H
#define COSMIC_STORE_H

#include "lua.h"
#include "sqlite3.h"

/* Installs the searcher, with `binary` as the last database searched.
 * `binary` may be NULL, which leaves the list empty until something is
 * attached. Also registers `cosmic.store` in package.preload. */
int cosmic_store_install(lua_State *L, sqlite3 *binary);

/* One entry of the meta table, or NULL. The string belongs to Lua and
 * stays valid until the next call that touches the stack. */
const char *cosmic_store_meta(lua_State *L, const char *key);

#endif
