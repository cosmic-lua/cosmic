/* Arithmetic on non-negative integers of thousands of bits, each a
 * big-endian byte string, over the vendored mbedtls's bignum. */

#ifndef COSMIC_BIGINT_H
#define COSMIC_BIGINT_H

#include "lua.h"

/* Opens the table that backs the [`cosmic.bigint`] wrapper, registered
 * under the raw [`cosmic.internal.bigint`] name. */
int cosmic_open_bigint (lua_State *L);

#endif
