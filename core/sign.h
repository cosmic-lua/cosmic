/* Ed25519 signatures (RFC 8032) over whole strings, computed by the
 * vendored Monocypher's `crypto_ed25519_*`. */

#ifndef COSMIC_SIGN_H
#define COSMIC_SIGN_H

#include "lua.h"

/* Opens the table that backs the [`cosmic.sign`] wrapper, registered
 * under the raw [`cosmic.internal.sign`] name. */
int cosmic_open_sign (lua_State *L);

#endif
