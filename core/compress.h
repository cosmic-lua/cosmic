/* Streaming compression codecs: deflate/zlib/gzip over the vendored
 * miniz, and the xz and bzip2 decoders, as userdata "stream" objects a
 * caller feeds chunks into. */

#ifndef COSMIC_COMPRESS_H
#define COSMIC_COMPRESS_H

#include <stddef.h>

#include "lua.h"

/* Opens the table that backs the `cosmic.compress` wrapper's streaming
 * codecs, registered under the raw `cosmic.internal.compress` name. */
int cosmic_open_compress (lua_State *L);

/* The raw deflate (RFC 1951) of the `len` bytes at `data`, at the level
 * `Compress.deflate("raw", data)` uses, so either side reads the other's:
 * a block from cosmic_malloc the caller frees, its length in `*out_len`,
 * or NULL when memory runs out. The same bytes in give the same bytes out,
 * which is what lets a build store them and stay reproducible. */
unsigned char *cosmic_deflate_raw (const void *data, size_t len,
                                   size_t *out_len);

/* What the raw deflate stream in the `len` bytes at `data` decodes to:
 * NULL on success, with `*out` a block from cosmic_malloc the caller
 * frees, `*out_len` bytes long and followed by a NUL it does not count;
 * otherwise why not -- the stream is damaged, truncated or followed by
 * more bytes, it decodes to more than `max` bytes, or memory ran out --
 * with `*out` NULL. */
const char *cosmic_inflate_raw (const void *data, size_t len, size_t max,
                                unsigned char **out, size_t *out_len);

#endif
