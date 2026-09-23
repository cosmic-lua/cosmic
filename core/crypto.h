/* Digests and HMAC over the vendored mbedtls, through its PSA API. */

#ifndef COSMIC_CRYPTO_H
#define COSMIC_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

/* The longest digest any algorithm here produces, in bytes. */
#define COSMIC_DIGEST_MAX 64

/* Brings the library up. Once per process, before any other call. */
int cosmic_crypto_init (void);

/* The raw digest of `data` under the algorithm `name` names: 0 on
 * success with `*out_len` set, -1 when no algorithm has that name, and
 * the library's own status otherwise. */
int cosmic_digest (const char *name, const void *data, size_t len,
                   unsigned char out[COSMIC_DIGEST_MAX], size_t *out_len);

/* Streaming digest of exactly `length` bytes from a positioned descriptor. */
int cosmic_digest_fd (const char *name, int fd, uint64_t offset,
                      uint64_t length,
                      unsigned char out[COSMIC_DIGEST_MAX], size_t *out_len);

/* HMAC of `data` under `key`, over the algorithm `name` names. Same
 * returns as `cosmic_digest`. */
int cosmic_hmac (const char *name, const void *key, size_t key_len,
                 const void *data, size_t len,
                 unsigned char out[COSMIC_DIGEST_MAX], size_t *out_len);

#endif
