/* Authenticated encryption of whole strings and X25519 key agreement,
 * over the vendored mbedtls through its PSA API. */

#ifndef COSMIC_CIPHER_H
#define COSMIC_CIPHER_H

#include "lua.h"

/* Opens the table that backs the [`cosmic.cipher`] wrapper, registered
 * under the raw [`cosmic.internal.cipher`] name. */
int cosmic_open_cipher (lua_State *L);

#endif
