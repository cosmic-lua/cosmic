/* Digests and HMACs of whole strings, and streaming digests: a userdata
 * object wrapping a PSA multipart hash operation, for data that arrives
 * in chunks rather than all at once. */

#ifndef COSMIC_HASH_H
#define COSMIC_HASH_H

#include "lua.h"

/* Opens the table that backs the `cosmic.hash` wrapper, registered
 * under the raw `cosmic.internal.hash` name. */
int cosmic_open_hash (lua_State *L);

#endif
