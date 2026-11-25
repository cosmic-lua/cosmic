#include "sign.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "lauxlib.h"
#include "mbedtls/platform_util.h"
#include "monocypher-ed25519.h"
#include "monocypher.h"
#include "psa/crypto.h"

enum { seed_size = 32, public_size = 32, secret_size = 64, signature_size = 64 };

/* Expands the seed at argument 1 into `public` and into `secret`,
 * Monocypher's signing key: the seed, then the public key. Raises on a
 * seed of another length. The caller wipes `secret`. */
static void key_pair (lua_State *L, uint8_t secret[secret_size],
                      uint8_t public[public_size]) {
  size_t size;
  const char *seed = luaL_checklstring(L, 1, &size);
  if (size != seed_size) {
    luaL_error(L, "sign: an Ed25519 seed is 32 bytes");
  }
  /* Monocypher wipes the seed it is given, so it gets a copy. */
  uint8_t copy[seed_size];
  memcpy(copy, seed, seed_size);
  crypto_ed25519_key_pair(secret, public, copy);
}

static int sign_ed25519_public (lua_State *L) {
  uint8_t secret[secret_size];
  uint8_t public[public_size];
  key_pair(L, secret, public);
  /* Before the push, which can raise on memory and leave this frame. */
  crypto_wipe(secret, sizeof secret);
  lua_pushlstring(L, (const char *)public, sizeof public);
  return 1;
}

static int sign_ed25519 (lua_State *L) {
  size_t size;
  const char *message = luaL_checklstring(L, 2, &size);
  uint8_t secret[secret_size];
  uint8_t public[public_size];
  uint8_t signature[signature_size];
  key_pair(L, secret, public);
  crypto_ed25519_sign(signature, secret, (const uint8_t *)message, size);
  /* Before the push, which can raise on memory and leave this frame. */
  crypto_wipe(secret, sizeof secret);
  lua_pushlstring(L, (const char *)signature, sizeof signature);
  return 1;
}

/* The encodings of the points of small order, the sign bit aside: y of
 * 0, 1, p - 1 and the two order-8 values, and the non-canonical p and
 * p + 1, which decode as 0 and 1. Under any of them as the key, one
 * signature (R the neutral point, S 0) verifies for every message. */
static const uint8_t small_order[][public_size] = {
  {0},
  {1},
  {0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4,
    0x89, 0xf2, 0xef, 0x98, 0xf0, 0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6,
    0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x05},
  {0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b,
    0x76, 0x0d, 0x10, 0x67, 0x0f, 0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39,
    0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0x7a},
  {0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f},
  {0xed, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f},
  {0xee, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f},
};

/* Whether the 32-byte key `public` is a point of small order. */
static bool of_small_order (const uint8_t *public) {
  for (size_t i = 0; i < sizeof small_order / sizeof small_order[0]; i++) {
    if (memcmp(public, small_order[i], public_size - 1) == 0 &&
        (public[public_size - 1] & 0x7f) == small_order[i][public_size - 1]) {
      return true;
    }
  }
  return false;
}

static int sign_ed25519_verify (lua_State *L) {
  size_t public_length;
  size_t message_length;
  size_t signature_length;
  const char *public = luaL_checklstring(L, 1, &public_length);
  const char *message = luaL_checklstring(L, 2, &message_length);
  const char *signature = luaL_checklstring(L, 3, &signature_length);
  bool verified = public_length == public_size &&
                  signature_length == signature_size &&
                  !of_small_order((const uint8_t *)public) &&
                  crypto_ed25519_check((const uint8_t *)signature,
                                       (const uint8_t *)public,
                                       (const uint8_t *)message,
                                       message_length) == 0;
  lua_pushboolean(L, verified);
  return 1;
}

enum {
  p256_secret_size = 32,
  p256_public_size = 65,
  p256_signature_size = 64,
};

/* The attributes of a P-256 key pair that signs SHA-256 digests by
 * deterministic ECDSA (RFC 6979): the signature is a function of the
 * key and the message, though mbedtls still draws entropy to blind the
 * computation. `usage` adds to signing, as PSA_KEY_USAGE_EXPORT does
 * for a new key that is exported. */
static psa_key_attributes_t p256_attributes (psa_key_usage_t usage) {
  psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
  psa_set_key_type(&attributes,
                   PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
  psa_set_key_bits(&attributes, 256);
  psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_SIGN_MESSAGE | usage);
  psa_set_key_algorithm(&attributes,
                        PSA_ALG_DETERMINISTIC_ECDSA(PSA_ALG_SHA_256));
  return attributes;
}

/* Imports the 32-byte secret at argument 1 as a volatile key. Raises on
 * a secret of another length, or one that is not a scalar from 1 to the
 * group order less 1, and on any other failure of the library, with its
 * status. The caller destroys the key before any Lua call that can
 * raise. */
static psa_key_id_t p256_import (lua_State *L) {
  size_t size;
  const char *secret = luaL_checklstring(L, 1, &size);
  if (size != p256_secret_size) {
    luaL_error(L, "sign: a P-256 secret is 32 bytes");
  }
  psa_key_attributes_t attributes = p256_attributes(0);
  psa_key_id_t key = PSA_KEY_ID_NULL;
  psa_status_t status = psa_import_key(&attributes, (const uint8_t *)secret,
                                       size, &key);
  if (status == PSA_ERROR_INVALID_ARGUMENT) {
    luaL_error(L, "sign: not a P-256 secret: no scalar from 1 to n - 1");
  }
  if (status != PSA_SUCCESS) {
    luaL_error(L, "sign: importing a P-256 secret failed (%d)", (int)status);
  }
  return key;
}

static int sign_p256_secret (lua_State *L) {
  psa_key_attributes_t attributes = p256_attributes(PSA_KEY_USAGE_EXPORT);
  psa_key_id_t key = PSA_KEY_ID_NULL;
  psa_status_t status = psa_generate_key(&attributes, &key);
  if (status != PSA_SUCCESS) {
    return luaL_error(L, "sign: generating a P-256 key failed (%d)",
                      (int)status);
  }
  uint8_t secret[p256_secret_size];
  size_t length = 0;
  status = psa_export_key(key, secret, sizeof secret, &length);
  psa_destroy_key(key);
  if (status != PSA_SUCCESS || length != sizeof secret) {
    mbedtls_platform_zeroize(secret, sizeof secret);
    return luaL_error(L, "sign: exporting a P-256 key failed (%d)",
                      (int)status);
  }
  /* A refused push raises past the wipe, leaving this frame's copy on
   * the stack; the key itself is already destroyed. */
  lua_pushlstring(L, (const char *)secret, sizeof secret);
  mbedtls_platform_zeroize(secret, sizeof secret);
  return 1;
}

static int sign_p256_public (lua_State *L) {
  psa_key_id_t key = p256_import(L);
  uint8_t public[p256_public_size];
  size_t length = 0;
  psa_status_t status = psa_export_public_key(key, public, sizeof public,
                                              &length);
  psa_destroy_key(key);
  if (status != PSA_SUCCESS || length != sizeof public) {
    return luaL_error(L, "sign: exporting a P-256 public key failed (%d)",
                      (int)status);
  }
  lua_pushlstring(L, (const char *)public, sizeof public);
  return 1;
}

static int sign_p256 (lua_State *L) {
  size_t size;
  const char *message = luaL_checklstring(L, 2, &size);
  psa_key_id_t key = p256_import(L);
  uint8_t signature[p256_signature_size];
  size_t length = 0;
  psa_status_t status = psa_sign_message(
      key, PSA_ALG_DETERMINISTIC_ECDSA(PSA_ALG_SHA_256),
      (const uint8_t *)message, size, signature, sizeof signature, &length);
  psa_destroy_key(key);
  if (status != PSA_SUCCESS || length != sizeof signature) {
    return luaL_error(L, "sign: P-256 signing failed (%d)", (int)status);
  }
  lua_pushlstring(L, (const char *)signature, sizeof signature);
  return 1;
}

static int sign_p256_verify (lua_State *L) {
  size_t public_length;
  size_t message_length;
  size_t signature_length;
  const char *public = luaL_checklstring(L, 1, &public_length);
  const char *message = luaL_checklstring(L, 2, &message_length);
  const char *signature = luaL_checklstring(L, 3, &signature_length);
  bool verified = false;
  if (public_length == p256_public_size &&
      signature_length == p256_signature_size) {
    psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attributes,
                     PSA_KEY_TYPE_ECC_PUBLIC_KEY(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&attributes, 256);
    psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_VERIFY_MESSAGE);
    psa_set_key_algorithm(&attributes, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
    psa_key_id_t key = PSA_KEY_ID_NULL;
    /* An import refuses a point that is not on the curve. Any failure,
     * the library's own included, makes verify return false: the
     * contract is that verify never raises. */
    if (psa_import_key(&attributes, (const uint8_t *)public, public_length,
                       &key) == PSA_SUCCESS) {
      verified = psa_verify_message(
                     key, PSA_ALG_ECDSA(PSA_ALG_SHA_256),
                     (const uint8_t *)message, message_length,
                     (const uint8_t *)signature, signature_length) ==
                 PSA_SUCCESS;
      psa_destroy_key(key);
    }
  }
  lua_pushboolean(L, verified);
  return 1;
}

enum {
  rsa_bits_min = 2048,
  rsa_bits_max = 4096,
  rsa_bits_default = 2048,
  rsa_secret_max = PSA_KEY_EXPORT_RSA_KEY_PAIR_MAX_SIZE(rsa_bits_max),
  rsa_public_max = PSA_KEY_EXPORT_RSA_PUBLIC_KEY_MAX_SIZE(rsa_bits_max),
  rsa_signature_max = PSA_BITS_TO_BYTES(rsa_bits_max),
};

/* The attributes of an RSA key of `type` and `bits` (0: any, as an
 * import reads them from the key) that signs or checks SHA-256 digests
 * by PKCS #1 v1.5, which JOSE calls RS256 and X.509
 * sha256WithRSAEncryption. */
static psa_key_attributes_t rsa_attributes (psa_key_type_t type, size_t bits,
                                            psa_key_usage_t usage) {
  psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
  psa_set_key_type(&attributes, type);
  psa_set_key_bits(&attributes, bits);
  psa_set_key_usage_flags(&attributes, usage);
  psa_set_key_algorithm(&attributes,
                        PSA_ALG_RSA_PKCS1V15_SIGN(PSA_ALG_SHA_256));
  return attributes;
}

/* The bits of `key`, or 0 when the library cannot say. */
static size_t rsa_bits (psa_key_id_t key) {
  psa_key_attributes_t got = PSA_KEY_ATTRIBUTES_INIT;
  size_t bits = 0;
  if (psa_get_key_attributes(key, &got) == PSA_SUCCESS) {
    bits = psa_get_key_bits(&got);
  }
  psa_reset_key_attributes(&got);
  return bits;
}

/* Imports the DER RSAPrivateKey at argument 1 as a volatile key. Raises
 * on bytes the library cannot read as one, on a key of fewer than 2048
 * bits or more than 4096 or whose modulus is not a whole number of
 * bytes, and on any other failure of the library, with
 * its status. The caller destroys the key before any Lua call that can
 * raise. */
static psa_key_id_t rsa_import (lua_State *L) {
  size_t size;
  const char *secret = luaL_checklstring(L, 1, &size);
  psa_key_attributes_t attributes = rsa_attributes(
      PSA_KEY_TYPE_RSA_KEY_PAIR, 0, PSA_KEY_USAGE_SIGN_MESSAGE);
  psa_key_id_t key = PSA_KEY_ID_NULL;
  psa_status_t status = psa_import_key(&attributes, (const uint8_t *)secret,
                                       size, &key);
  /* The library refuses a key of more than 4096 bits, or of a modulus
   * that is not a whole number of bytes, as not supported. */
  if (status == PSA_ERROR_NOT_SUPPORTED) {
    luaL_error(L,
               "sign: an RSA key is from 2048 to 4096 bits, in whole bytes");
  }
  /* The library returns a generic error for bytes after the key's
   * SEQUENCE, or a component of zero. */
  if (status == PSA_ERROR_INVALID_ARGUMENT ||
      status == PSA_ERROR_GENERIC_ERROR) {
    luaL_error(L, "sign: not an RSA secret: no DER RSAPrivateKey");
  }
  if (status != PSA_SUCCESS) {
    luaL_error(L, "sign: importing an RSA secret failed (%d)", (int)status);
  }
  size_t bits = rsa_bits(key);
  if (bits < rsa_bits_min || bits > rsa_bits_max) {
    psa_destroy_key(key);
    luaL_error(L,
               "sign: an RSA key is from 2048 to 4096 bits, in whole bytes");
  }
  return key;
}

static int sign_rsa_secret (lua_State *L) {
  lua_Integer bits = luaL_optinteger(L, 1, rsa_bits_default);
  if (bits != 2048 && bits != 3072 && bits != 4096) {
    return luaL_error(L, "sign: a new RSA key is 2048, 3072 or 4096 bits");
  }
  psa_key_attributes_t attributes =
      rsa_attributes(PSA_KEY_TYPE_RSA_KEY_PAIR, (size_t)bits,
                     PSA_KEY_USAGE_SIGN_MESSAGE | PSA_KEY_USAGE_EXPORT);
  psa_key_id_t key = PSA_KEY_ID_NULL;
  psa_status_t status = psa_generate_key(&attributes, &key);
  if (status != PSA_SUCCESS) {
    return luaL_error(L, "sign: generating an RSA key failed (%d)",
                      (int)status);
  }
  uint8_t secret[rsa_secret_max];
  size_t length = 0;
  status = psa_export_key(key, secret, sizeof secret, &length);
  psa_destroy_key(key);
  if (status != PSA_SUCCESS) {
    mbedtls_platform_zeroize(secret, sizeof secret);
    return luaL_error(L, "sign: exporting an RSA key failed (%d)",
                      (int)status);
  }
  /* A refused push raises past the wipe, leaving this frame's copy on
   * the stack; the key itself is already destroyed. */
  lua_pushlstring(L, (const char *)secret, length);
  mbedtls_platform_zeroize(secret, sizeof secret);
  return 1;
}

static int sign_rsa_public (lua_State *L) {
  psa_key_id_t key = rsa_import(L);
  uint8_t public[rsa_public_max];
  size_t length = 0;
  psa_status_t status = psa_export_public_key(key, public, sizeof public,
                                              &length);
  psa_destroy_key(key);
  if (status != PSA_SUCCESS) {
    return luaL_error(L, "sign: exporting an RSA public key failed (%d)",
                      (int)status);
  }
  lua_pushlstring(L, (const char *)public, length);
  return 1;
}

static int sign_rsa (lua_State *L) {
  size_t size;
  const char *message = luaL_checklstring(L, 2, &size);
  psa_key_id_t key = rsa_import(L);
  uint8_t signature[rsa_signature_max];
  size_t length = 0;
  psa_status_t status = psa_sign_message(
      key, PSA_ALG_RSA_PKCS1V15_SIGN(PSA_ALG_SHA_256),
      (const uint8_t *)message, size, signature, sizeof signature, &length);
  psa_destroy_key(key);
  if (status != PSA_SUCCESS) {
    return luaL_error(L, "sign: RSA signing failed (%d)", (int)status);
  }
  lua_pushlstring(L, (const char *)signature, length);
  return 1;
}

static int sign_rsa_verify (lua_State *L) {
  size_t public_length;
  size_t message_length;
  size_t signature_length;
  const char *public = luaL_checklstring(L, 1, &public_length);
  const char *message = luaL_checklstring(L, 2, &message_length);
  const char *signature = luaL_checklstring(L, 3, &signature_length);
  bool verified = false;
  if (public_length <= rsa_public_max &&
      signature_length <= rsa_signature_max) {
    psa_key_attributes_t attributes = rsa_attributes(
        PSA_KEY_TYPE_RSA_PUBLIC_KEY, 0, PSA_KEY_USAGE_VERIFY_MESSAGE);
    psa_key_id_t key = PSA_KEY_ID_NULL;
    /* Any failure, the library's own included, makes verify return
     * false: the contract is that verify never raises. A key outside 2048
     * to 4096 bits makes it return false too, as signing refuses one. */
    if (psa_import_key(&attributes, (const uint8_t *)public, public_length,
                       &key) == PSA_SUCCESS) {
      size_t bits = rsa_bits(key);
      verified = bits >= rsa_bits_min && bits <= rsa_bits_max &&
                 signature_length == PSA_BITS_TO_BYTES(bits) &&
                 psa_verify_message(
                     key, PSA_ALG_RSA_PKCS1V15_SIGN(PSA_ALG_SHA_256),
                     (const uint8_t *)message, message_length,
                     (const uint8_t *)signature, signature_length) ==
                     PSA_SUCCESS;
      psa_destroy_key(key);
    }
  }
  lua_pushboolean(L, verified);
  return 1;
}

static const luaL_Reg module[] = {
  {"ed25519_public", sign_ed25519_public},
  {"ed25519", sign_ed25519},
  {"ed25519_verify", sign_ed25519_verify},
  {"p256_secret", sign_p256_secret},
  {"p256_public", sign_p256_public},
  {"p256", sign_p256},
  {"p256_verify", sign_p256_verify},
  {"rsa_secret", sign_rsa_secret},
  {"rsa_public", sign_rsa_public},
  {"rsa", sign_rsa},
  {"rsa_verify", sign_rsa_verify},
  {NULL, NULL},
};

int cosmic_open_sign (lua_State *L) {
  luaL_newlib(L, module);
  return 1;
}
