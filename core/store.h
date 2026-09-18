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
 * attached. The raw `cosmic.store` value goes in the registry, never in
 * package.preload: only a caller the searcher itself trusts ever gets
 * it back. */
int cosmic_store_install(lua_State *L, sqlite3 *binary);

/* Registers the value on top of the stack (popped) as the raw module a
 * trusted caller's `require(name)` resolves to. `name` is "cosmic.store"
 * or "cosmic.sqlite"; nothing else is ever looked up this way. */
void cosmic_store_set_raw(lua_State *L, const char *name);

/* Puts the raw value already registered under `name` (see
 * cosmic_store_set_raw) into package.preload, unconditionally. Boot mode
 * is the only caller: before any database is attached, the whole tree is
 * trusted source, and the bridge's own searcher does not go through the
 * trust-gated store searcher at all. A shipped binary never calls this. */
void cosmic_store_preload_raw(lua_State *L, const char *name);

/* One entry of the meta table, or NULL. The string belongs to Lua and
 * stays valid until the next call that touches the stack. */
const char *cosmic_store_meta(lua_State *L, const char *key);

#endif
