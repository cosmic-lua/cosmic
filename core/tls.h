/* TLS for [`cosmic.net`], over mbedtls: a server's configuration of
 * certificates and keys, under its TLS listeners; a client's of the
 * roots it verifies a server against, under [`Net.connect`]'s `tls`;
 * and a session of either over one socket. */

#ifndef COSMIC_TLS_H
#define COSMIC_TLS_H

#include "lua.h"

/* Opens the table registered under the raw [`cosmic.internal.tls`]
 * name. */
int cosmic_open_tls (lua_State *L);

#endif
