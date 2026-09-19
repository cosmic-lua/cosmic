#include "crypto.h"

/* getentropy is a BSD call both systems have: musl shows it under
 * _DEFAULT_SOURCE, Darwin in its own header. */
#define _DEFAULT_SOURCE
#include <string.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/random.h>
#endif

#include "psa/crypto.h"

/* The library is built with an external random generator, which keeps
 * its entropy and DRBG modules out of the core. Nothing here draws
 * randomness today; this is what will, over the same two OS calls both
 * targets have. */
psa_status_t mbedtls_psa_external_get_random(
    mbedtls_psa_external_random_context_t *context, uint8_t *output,
    size_t output_size, size_t *output_length) {
  (void)context;
  size_t got = 0;
  while (got < output_size) {
    size_t want = output_size - got;
    if (want > 256) {
      want = 256; /* getentropy's own ceiling */
    }
    if (getentropy(output + got, want) != 0) {
      return PSA_ERROR_INSUFFICIENT_ENTROPY;
    }
    got += want;
  }
  *output_length = got;
  return PSA_SUCCESS;
}

struct algorithm {
  const char *name;
  psa_algorithm_t alg;
};

static const struct algorithm algorithms[] = {
    {"md5", PSA_ALG_MD5},         {"sha1", PSA_ALG_SHA_1},
    {"sha224", PSA_ALG_SHA_224},  {"sha256", PSA_ALG_SHA_256},
    {"sha384", PSA_ALG_SHA_384},  {"sha512", PSA_ALG_SHA_512},
    {"sha3-224", PSA_ALG_SHA3_224}, {"sha3-256", PSA_ALG_SHA3_256},
    {"sha3-384", PSA_ALG_SHA3_384}, {"sha3-512", PSA_ALG_SHA3_512},
};

const char *const cosmic_crypto_algorithms[] = {
    "md5",    "sha1",     "sha224",   "sha256",   "sha384", "sha512",
    "sha3-224", "sha3-256", "sha3-384", "sha3-512", NULL,
};

static psa_algorithm_t by_name(const char *name) {
  for (size_t i = 0; i < sizeof algorithms / sizeof *algorithms; i++) {
    if (strcmp(algorithms[i].name, name) == 0) {
      return algorithms[i].alg;
    }
  }
  return PSA_ALG_NONE;
}

int cosmic_crypto_init(void) {
  return (int)psa_crypto_init();
}

int cosmic_digest(const char *name, const void *data, size_t len,
                  unsigned char out[COSMIC_DIGEST_MAX], size_t *out_len) {
  psa_algorithm_t alg = by_name(name);
  if (alg == PSA_ALG_NONE) {
    return -1;
  }
  return (int)psa_hash_compute(alg, data, len, out, COSMIC_DIGEST_MAX,
                               out_len);
}

int cosmic_hmac(const char *name, const void *key, size_t key_len,
                const void *data, size_t len,
                unsigned char out[COSMIC_DIGEST_MAX], size_t *out_len) {
  psa_algorithm_t alg = by_name(name);
  if (alg == PSA_ALG_NONE) {
    return -1;
  }
  /* A key lives in the library's own slot for exactly one computation:
   * imported, used, destroyed. */
  psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
  psa_set_key_type(&attributes, PSA_KEY_TYPE_HMAC);
  psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_SIGN_MESSAGE);
  psa_set_key_algorithm(&attributes, PSA_ALG_HMAC(alg));
  psa_key_id_t id = 0;
  psa_status_t status = psa_import_key(&attributes, key, key_len, &id);
  if (status != PSA_SUCCESS) {
    return (int)status;
  }
  status = psa_mac_compute(id, PSA_ALG_HMAC(alg), data, len, out,
                           COSMIC_DIGEST_MAX, out_len);
  psa_destroy_key(id);
  return (int)status;
}
