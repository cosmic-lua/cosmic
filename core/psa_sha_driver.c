/* See psa_sha_driver.h for the driver's place in the dispatch. The
 * whole accelerated path is x86_64-only: on any other architecture
 * every entry point returns PSA_ERROR_NOT_SUPPORTED and the dispatch
 * uses the built-in software SHA-256, exactly as if the driver were
 * not compiled in. */

#include "psa_sha_driver.h"

#include <stdbool.h>
#include <string.h>

#include "mbedtls/platform_util.h"

#if defined(__x86_64__)
#include <cpuid.h>
#include <immintrin.h>
#endif

#if defined(__x86_64__)

static const uint32_t cosmic_sha256_initial[8] = {
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

static const uint32_t cosmic_sha224_initial[8] = {
  0xc1059ed8, 0x367cd507, 0x3070dd17, 0xf70e5939,
  0xffc00b31, 0x68581511, 0x64f98fa7, 0xbefa4fa4};

/* Whether this CPU can run the compress below: the SHA extensions
 * (cpuid leaf 7, EBX bit 29) for the rounds and message schedule,
 * plus SSSE3 (leaf 1, ECX bit 9) for the byte shuffle and SSE4.1
 * (leaf 1, ECX bit 19) for the blend the state shuffle uses. Asked
 * once and cached; the answer cannot change under a running
 * process. These are three of the processor features
 * [`sys.cpu_features`] reports (sha_ni, ssse3, sse4_1); see
 * build/dispatched_features_test.tl for the audit of every asking
 * site. */
static bool cosmic_sha_ni_present (void) {
  static int present = -1;
  if (present < 0) {
    unsigned int eax, ebx, ecx, edx;
    present = 0;
    if (__get_cpuid (1, &eax, &ebx, &ecx, &edx) &&
        (ecx & bit_SSSE3) != 0 && (ecx & bit_SSE4_1) != 0 &&
        __get_cpuid_count (7, 0, &eax, &ebx, &ecx, &edx) &&
        (ebx & bit_SHA) != 0) {
      present = 1;
    }
  }
  return present != 0;
}

static const uint32_t cosmic_sha256_round_constants[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

/* One 64-byte block through the SHA-256 compression function, with
 * the message schedule computed four words at a time as the rounds
 * consume it. The core is built for a baseline CPU, so the SHA and
 * shuffle instructions live behind a per-function target; the only
 * caller is guarded by [`cosmic_sha_ni_present`].
 *
 * sha256rnds2 takes its two state operands in a split layout: with
 * the working variables (a..h) it wants lanes [h, g, d, c] in the
 * first and [f, e, b, a] in the second, and returns the second's
 * group updated. After a pair of rounds the two groups have traded
 * places -- the old [f, e, b, a] register is exactly the [h, g, d, c]
 * the next pair needs -- so the registers simply alternate. */
__attribute__((target("sha,ssse3,sse4.1"))) static void
cosmic_sha256_compress (uint32_t state[8], const uint8_t *block) {
  const __m128i byte_shuffle = _mm_set_epi64x (0x0c0d0e0f08090a0b,
                                               0x0405060700010203);
  __m128i w[16];
  for (int i = 0; i < 4; i++) {
    w[i] = _mm_shuffle_epi8 (
        _mm_loadu_si128 ((const __m128i *)(block + 16 * i)), byte_shuffle);
  }
  __m128i abcd = _mm_loadu_si128 ((const __m128i *)state);
  __m128i efgh = _mm_loadu_si128 ((const __m128i *)(state + 4));
  /* The two state registers in sha256rnds2's layout, lanes [h, g, d,
   * c] and [f, e, b, a]. */
  __m128i hgdc = _mm_alignr_epi8 (_mm_shuffle_epi32 (abcd, 0x1B),
                                  _mm_shuffle_epi32 (efgh, 0xB1), 8);
  __m128i feba = _mm_alignr_epi8 (_mm_shuffle_epi32 (abcd, 0xB1),
                                  _mm_shuffle_epi32 (efgh, 0x1B), 8);
  for (int round = 0; round < 16; round++) {
    __m128i msg = w[round];
    if (round >= 4) {
      msg = _mm_add_epi32 (
          _mm_sha256msg1_epu32 (w[round - 4], w[round - 3]),
          _mm_alignr_epi8 (w[round - 1], w[round - 2], 4));
      msg = _mm_sha256msg2_epu32 (msg, w[round - 1]);
      w[round] = msg;
    }
    __m128i wk = _mm_add_epi32 (
        msg, _mm_loadu_si128 ((const __m128i *)(cosmic_sha256_round_constants +
                                                4 * round)));
    hgdc = _mm_sha256rnds2_epu32 (hgdc, feba, wk);
    wk = _mm_shuffle_epi32 (wk, 0x0E);
    feba = _mm_sha256rnds2_epu32 (feba, hgdc, wk);
  }
  /* Back to lanes [a, b, c, d] and [e, f, g, h]: feba holds the
   * final [f, e, b, a], and hgdc the [f, e, b, a] of four rounds
   * earlier, whose values are the final c, d, g, h. Add the incoming
   * state, as the definition asks. */
  __m128i out_abcd = _mm_alignr_epi8 (_mm_shuffle_epi32 (hgdc, 0x1B),
                                      _mm_shuffle_epi32 (feba, 0xB1), 8);
  __m128i out_efgh = _mm_alignr_epi8 (_mm_shuffle_epi32 (hgdc, 0xB1),
                                      _mm_shuffle_epi32 (feba, 0x1B), 8);
  _mm_storeu_si128 ((__m128i *)state, _mm_add_epi32 (out_abcd, abcd));
  _mm_storeu_si128 ((__m128i *)(state + 4), _mm_add_epi32 (out_efgh, efgh));
}

static void cosmic_sha256_blocks (cosmic_psa_sha_operation_t *operation,
                                  const uint8_t *data, size_t length) {
  while (length >= 64) {
    cosmic_sha256_compress (operation->state, data);
    data += 64;
    length -= 64;
  }
}

#endif /* __x86_64__ */

psa_status_t cosmic_psa_hash_setup (cosmic_psa_sha_operation_t *operation,
                                    psa_algorithm_t alg) {
#if defined(__x86_64__)
  if (alg != PSA_ALG_SHA_256 && alg != PSA_ALG_SHA_224) {
    return PSA_ERROR_NOT_SUPPORTED;
  }
  if (!cosmic_sha_ni_present ()) {
    return PSA_ERROR_NOT_SUPPORTED;
  }
  operation->alg = alg;
  memcpy (operation->state,
          alg == PSA_ALG_SHA_224 ? cosmic_sha224_initial
                                 : cosmic_sha256_initial,
          sizeof operation->state);
  operation->length = 0;
  operation->buffered = 0;
  return PSA_SUCCESS;
#else
  (void) operation;
  (void) alg;
  return PSA_ERROR_NOT_SUPPORTED;
#endif
}

psa_status_t cosmic_psa_hash_update (cosmic_psa_sha_operation_t *operation,
                                     const uint8_t *input,
                                     size_t input_length) {
#if defined(__x86_64__)
  if (operation->alg == PSA_ALG_NONE) {
    return PSA_ERROR_BAD_STATE;
  }
  if (input_length == 0) {
    return PSA_SUCCESS;
  }
  operation->length += input_length;
  if (operation->buffered > 0) {
    size_t take = 64 - operation->buffered;
    if (take > input_length) {
      take = input_length;
    }
    memcpy (operation->buffer + operation->buffered, input, take);
    operation->buffered += take;
    input += take;
    input_length -= take;
    if (operation->buffered == 64) {
      cosmic_sha256_compress (operation->state, operation->buffer);
      operation->buffered = 0;
    }
  }
  if (input_length >= 64) {
    size_t whole = input_length & ~(size_t)63;
    cosmic_sha256_blocks (operation, input, whole);
    input += whole;
    input_length -= whole;
  }
  if (input_length > 0) {
    memcpy (operation->buffer, input, input_length);
    operation->buffered = input_length;
  }
  return PSA_SUCCESS;
#else
  (void) operation;
  (void) input;
  (void) input_length;
  return PSA_ERROR_NOT_SUPPORTED;
#endif
}

psa_status_t cosmic_psa_hash_clone (
    const cosmic_psa_sha_operation_t *source_operation,
    cosmic_psa_sha_operation_t *target_operation) {
  *target_operation = *source_operation;
  return PSA_SUCCESS;
}

psa_status_t cosmic_psa_hash_finish (cosmic_psa_sha_operation_t *operation,
                                     uint8_t *hash, size_t hash_size,
                                     size_t *hash_length) {
#if defined(__x86_64__)
  size_t length = PSA_HASH_LENGTH (operation->alg);
  if (hash_size < length) {
    return PSA_ERROR_BUFFER_TOO_SMALL;
  }
  /* The padding is worked on a copy, so a caller that keeps the
   * operation after a failed finish is not left with a half-padded
   * state. */
  cosmic_psa_sha_operation_t done = *operation;
  uint64_t bits = done.length * 8;
  uint8_t pad = 0x80;
  cosmic_psa_hash_update (&done, &pad, 1);
  uint8_t zero = 0;
  while (done.buffered != 56) {
    cosmic_psa_hash_update (&done, &zero, 1);
  }
  for (int i = 0; i < 8; i++) {
    done.buffer[56 + i] = (uint8_t)(bits >> (56 - 8 * i));
  }
  cosmic_sha256_compress (done.state, done.buffer);
  for (size_t i = 0; i < length / 4; i++) {
    hash[4 * i] = (uint8_t)(done.state[i] >> 24);
    hash[4 * i + 1] = (uint8_t)(done.state[i] >> 16);
    hash[4 * i + 2] = (uint8_t)(done.state[i] >> 8);
    hash[4 * i + 3] = (uint8_t)done.state[i];
  }
  *hash_length = length;
  mbedtls_platform_zeroize (&done, sizeof done);
  return cosmic_psa_hash_abort (operation);
#else
  (void) operation;
  (void) hash;
  (void) hash_size;
  (void) hash_length;
  return PSA_ERROR_NOT_SUPPORTED;
#endif
}

psa_status_t cosmic_psa_hash_abort (cosmic_psa_sha_operation_t *operation) {
  mbedtls_platform_zeroize (operation, sizeof *operation);
  return PSA_SUCCESS;
}

psa_status_t cosmic_psa_hash_compute (psa_algorithm_t alg,
                                      const uint8_t *input,
                                      size_t input_length, uint8_t *hash,
                                      size_t hash_size,
                                      size_t *hash_length) {
  cosmic_psa_sha_operation_t operation;
  psa_status_t status = cosmic_psa_hash_setup (&operation, alg);
  if (status != PSA_SUCCESS) {
    return status;
  }
  status = cosmic_psa_hash_update (&operation, input, input_length);
  if (status == PSA_SUCCESS) {
    status = cosmic_psa_hash_finish (&operation, hash, hash_size, hash_length);
  }
  if (status != PSA_SUCCESS) {
    cosmic_psa_hash_abort (&operation);
  }
  return status;
}
