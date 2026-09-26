/* Digests and HMAC over the vendored mbedtls, through its PSA API. */

#ifndef COSMIC_CRYPTO_H
#define COSMIC_CRYPTO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "psa/crypto.h"

/* A sha256 digest's length, in bytes. */
#define COSMIC_SHA256_LENGTH 32

/* The longest digest any algorithm here produces, in bytes. */
#define COSMIC_DIGEST_MAX 64

/* The most bytes one `sys.entropy` call draws. */
#define COSMIC_ENTROPY_MAX (1 << 20)

/* The PSA algorithm an algorithm name names, or PSA_ALG_NONE when no
 * algorithm has that name. Shared with the streaming hasher, so the
 * name-to-algorithm table lives in exactly one place. */
psa_algorithm_t cosmic_hash_algorithm (const char *name);

/* Fills `out` with `len` bytes from the operating system's entropy
 * source: 0 on success, an errno otherwise. */
int cosmic_entropy (void *out, size_t len);

/* Brings the library up. Once per process, before any other call.
 * Returns the library's own status, PSA_SUCCESS (0) when it is up. */
int cosmic_crypto_init (void);

/* The raw digest of `data` under the algorithm `name` names: 0 on
 * success with `*out_len` set, -1 when no algorithm has that name, and
 * the library's own status otherwise. */
int cosmic_digest (const char *name, const void *data, size_t len,
                   unsigned char out[COSMIC_DIGEST_MAX], size_t *out_len);

/* HMAC of `data` under `key`, over the algorithm `name` names. Same
 * returns as `cosmic_digest`. */
int cosmic_hmac (const char *name, const void *key, size_t key_len,
                 const void *data, size_t len,
                 unsigned char out[COSMIC_DIGEST_MAX], size_t *out_len);

/* Whether the `length` bytes at `offset` in `fd` hash, under sha256, to
 * the bytes `want` holds. False on any read or digest failure too. */
bool cosmic_sha256_range_matches (int fd, uint64_t offset, uint64_t length,
                                  const unsigned char want[COSMIC_SHA256_LENGTH]);

/* Writes `length` bytes as lowercase hex, two characters each, into
 * `out`, and a NUL after them: `out` holds 2 * length + 1. */
static inline void cosmic_hex (char *out, const unsigned char *bytes,
                               size_t length) {
  static const char digits[] = "0123456789abcdef";
  for (size_t i = 0; i < length; i++) {
    out[2 * i] = digits[bytes[i] >> 4];
    out[2 * i + 1] = digits[bytes[i] & 15];
  }
  out[2 * length] = '\0';
}

#endif
