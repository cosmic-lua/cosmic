/* A transparent PSA hash driver for SHA-224 and SHA-256 on x86_64,
 * accelerated with the SHA extensions (SHA-NI). It sits in front of
 * the vendored library's software SHA-256: the dispatch in
 * psa_crypto_driver_wrappers.h (see patch/mbedtls) tries this driver
 * first, and a PSA_ERROR_NOT_SUPPORTED -- an algorithm it does not
 * claim, or a CPU without the extensions -- falls back to the
 * built-in. Upstream mbedtls has no x86 SHA code at all
 * (Mbed-TLS/mbedtls#8739), so the driver is cosmic's own code, in
 * cosmic's core, not a patch on the vendored sha256.c.
 *
 * TODO: claim SHA-384 and SHA-512, and an aarch64 compress, too.
 * Each is a second state and schedule beside this one -- wider
 * words for the 512 family, another detection and register layout
 * on aarch64 -- and this proof of concept settles for the two
 * digests cosmic's own hashing leans on. */

#ifndef COSMIC_PSA_SHA_DRIVER_H
#define COSMIC_PSA_SHA_DRIVER_H

#include <stddef.h>
#include <stdint.h>

#include "psa/crypto.h"

/* One SHA-224/256 operation's whole state: plain data (an
 * algorithm, eight state words, a byte count, one partial block
 * and its fill), so clone is a struct copy. The definition is the
 * contexts patch's too (patch/mbedtls, in
 * crypto_driver_contexts_primitives.h, whose union it is a member
 * of): whichever of that header and this one a translation unit
 * reaches first defines it, under this shared guard, and the other
 * stands down -- the PSA core and this driver must agree on the
 * layout, so the two definitions are the same text. */
#ifndef COSMIC_PSA_SHA_OPERATION_T_DEFINED
#define COSMIC_PSA_SHA_OPERATION_T_DEFINED
typedef struct {
  psa_algorithm_t alg;
  uint32_t state[8];
  uint64_t length;
  uint8_t buffer[64];
  size_t buffered;
} cosmic_psa_sha_operation_t;
#endif

/* The entry points, with the signatures of the
 * mbedtls_test_transparent_hash_* ones they sit beside in the
 * dispatch. Each returns PSA_ERROR_NOT_SUPPORTED for an algorithm
 * the driver does not claim, and on a CPU without the extensions. */
psa_status_t cosmic_psa_hash_compute (psa_algorithm_t alg,
                                      const uint8_t *input,
                                      size_t input_length, uint8_t *hash,
                                      size_t hash_size,
                                      size_t *hash_length);
psa_status_t cosmic_psa_hash_setup (cosmic_psa_sha_operation_t *operation,
                                    psa_algorithm_t alg);
psa_status_t cosmic_psa_hash_clone (
    const cosmic_psa_sha_operation_t *source_operation,
    cosmic_psa_sha_operation_t *target_operation);
psa_status_t cosmic_psa_hash_update (cosmic_psa_sha_operation_t *operation,
                                     const uint8_t *input,
                                     size_t input_length);
psa_status_t cosmic_psa_hash_finish (cosmic_psa_sha_operation_t *operation,
                                     uint8_t *hash, size_t hash_size,
                                     size_t *hash_length);
psa_status_t cosmic_psa_hash_abort (cosmic_psa_sha_operation_t *operation);

#endif
