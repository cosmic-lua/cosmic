/* Streaming compression codecs: deflate/zlib/gzip over the vendored
 * miniz, and the xz and bzip2 decoders, as userdata "stream" objects a
 * caller feeds chunks into. */

#ifndef COSMIC_COMPRESS_H
#define COSMIC_COMPRESS_H

#include "lua.h"

/* Opens the table that backs the `cosmic.compress` wrapper's streaming
 * codecs, registered under the raw `cosmic.internal.compress` name. */
int cosmic_open_compress (lua_State *L);

#endif
