/* SHA-256 over a stream of bytes. */

#ifndef COSMIC_SHA256_H
#define COSMIC_SHA256_H

#include <stddef.h>
#include <stdint.h>

struct cosmic_sha256 {
  uint32_t state[8];
  uint64_t length;
  unsigned char block[64];
  size_t held;
};

void cosmic_sha256_begin(struct cosmic_sha256 *s);
void cosmic_sha256_add(struct cosmic_sha256 *s, const void *data, size_t len);
void cosmic_sha256_end(struct cosmic_sha256 *s, unsigned char out[32]);

/* The whole of one buffer, for a caller with no stream. */
void cosmic_sha256(const void *data, size_t len, unsigned char out[32]);

#endif
