/*
 * The module store. `require` reads a database and nothing else: a `.tl`
 * on disk is input to the build, never to the runtime.
 *
 * More than one database can be in play. A project's own build database
 * is searched ahead of the one carried by the portable artifact, which is how the
 * tool builds and runs a tree other than its own.
 */

#ifndef COSMIC_STORE_H
#define COSMIC_STORE_H

#include "lua.h"
#include "sqlite3.h"

struct cosmic_artifact;

/* Installs the searcher, with `binary` as the last database searched.
 * `binary` may be NULL, which leaves the list empty until something is
 * opened. The raw `cosmic.internal.store` value goes in the registry,
 * never in package.preload: only a caller the searcher itself trusts
 * ever gets it back. */
int cosmic_store_install (lua_State *L, sqlite3 *binary,
                          const struct cosmic_artifact *artifact);

/* Registers the value on top of the stack (popped) as the raw module a
 * trusted caller's `require(name)` resolves to. `name` is
 * "cosmic.internal.store", "cosmic.internal.sqlite", or
 * "cosmic.internal.debug"; nothing else is ever looked up this way. */
void cosmic_store_set_raw (lua_State *L, const char *name);

/* Puts the raw value already registered under `name` (see
 * cosmic_store_set_raw) into package.preload, unconditionally. Boot mode
 * is the only caller: before any artifact database is opened, the whole tree is
 * trusted source, and the bridge's own searcher does not go through the
 * trust-gated store searcher at all. A shipped binary never calls this. */
void cosmic_store_preload_raw (lua_State *L, const char *name);

/* Copies one entry of the meta table into `out`, NUL-terminated. Returns
 * 0 when the entry is missing, cannot be read, or does not fit in `size`
 * bytes; `out` is then an empty string. */
int cosmic_store_meta (lua_State *L, const char *key, char *out, size_t size);

/* The databases `require` searches, in search order: how many there
 * are, and the connection at 1-based `index` (NULL past the end). The
 * last one is always the binary's own. */
int cosmic_store_count (lua_State *L);

/* The validated portable artifact this process was started from, or NULL
 * for a native start. It stays owned by the entry. */
const struct cosmic_artifact *cosmic_store_artifact (lua_State *L);
sqlite3 *cosmic_store_database (lua_State *L, int index);

#endif
