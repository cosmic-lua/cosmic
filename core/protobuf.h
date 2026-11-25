/* The Protocol Buffers wire format, read by number: nanopb reads the
 * bytes, this core indexes the fields and returns each by its type. */

#ifndef COSMIC_PROTOBUF_H
#define COSMIC_PROTOBUF_H

#include "lua.h"

/* Opens the table that backs the [`cosmic.protobuf`] wrapper, registered
 * under the raw [`cosmic.internal.protobuf`] name. */
int cosmic_open_protobuf (lua_State *L);

#endif
