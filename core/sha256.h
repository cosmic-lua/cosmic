/* SHA-256 over one buffer. */

#ifndef COSMIC_SHA256_H
#define COSMIC_SHA256_H

#include <stddef.h>

void cosmic_sha256(const void *data, size_t len, unsigned char out[32]);

#endif
