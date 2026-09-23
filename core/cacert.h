/*
 * The Mozilla CA bundle (vendor/cacert/cacert.pem), embedded into the
 * core at build time by core/cacert.zig; see there for why it is PEM.
 * Not NUL-terminated as a C string -- `cosmic_cacert_pem_len` is the
 * byte count `CURLOPT_CAINFO_BLOB` wants, not a string length.
 */
#ifndef COSMIC_CACERT_H
#define COSMIC_CACERT_H

#include <stddef.h>

extern const unsigned char cosmic_cacert_pem[];
extern const size_t cosmic_cacert_pem_len;

#endif /* COSMIC_CACERT_H */
