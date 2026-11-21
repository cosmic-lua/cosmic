/* The TLS server under [`cosmic.net`]'s TLS listeners, over mbedtls: a
 * configuration of certificates and keys, and a session of it over one
 * accepted socket. */

#ifndef COSMIC_TLS_H
#define COSMIC_TLS_H

#include "lua.h"

/* Opens the table registered under the raw [`cosmic.internal.tls`]
 * name. */
int cosmic_open_tls (lua_State *L);

#endif
