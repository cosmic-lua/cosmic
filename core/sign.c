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

static int sign_ed25519_verify (lua_State *L) {
  size_t public_length;
  size_t message_length;
  size_t signature_length;
  const char *public = luaL_checklstring(L, 1, &public_length);
  const char *message = luaL_checklstring(L, 2, &message_length);
  const char *signature = luaL_checklstring(L, 3, &signature_length);
  bool verified = public_length == public_size &&
                  signature_length == signature_size &&
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
 * deterministic ECDSA (RFC 6979), so no signature draws entropy. */
static psa_key_attributes_t p256_attributes (void) {
  psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
  psa_set_key_type(&attributes,
                   PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
  psa_set_key_bits(&attributes, 256);
  psa_set_key_usage_flags(&attributes,
                          PSA_KEY_USAGE_SIGN_MESSAGE | PSA_KEY_USAGE_EXPORT);
  psa_set_key_algorithm(&attributes,
                        PSA_ALG_DETERMINISTIC_ECDSA(PSA_ALG_SHA_256));
  return attributes;
}

/* Imports the 32-byte secret at argument 1 as a volatile key. Raises on
 * a secret of another length, or one that is not a scalar from 1 to the
 * group order less 1. The caller destroys the key before any Lua call
 * that can raise. */
static psa_key_id_t p256_import (lua_State *L) {
  size_t size;
  const char *secret = luaL_checklstring(L, 1, &size);
  if (size != p256_secret_size) {
    luaL_error(L, "sign: a P-256 secret is 32 bytes");
  }
  psa_key_attributes_t attributes = p256_attributes();
  psa_key_id_t key = PSA_KEY_ID_NULL;
  psa_status_t status = psa_import_key(&attributes, (const uint8_t *)secret,
                                       size, &key);
  if (status != PSA_SUCCESS) {
    luaL_error(L, "sign: not a P-256 secret: no scalar from 1 to n - 1");
  }
  return key;
}

static int sign_p256_secret (lua_State *L) {
  /* The secret is exported straight into the result's buffer, sized
   * before the key exists, so no Lua call that can raise comes between
   * the key's creation and its destruction, and no copy is left on the
   * C stack. */
  luaL_Buffer buffer;
  char *out = luaL_buffinitsize(L, &buffer, p256_secret_size);
  psa_key_attributes_t attributes = p256_attributes();
  psa_key_id_t key = PSA_KEY_ID_NULL;
  psa_status_t status = psa_generate_key(&attributes, &key);
  if (status != PSA_SUCCESS) {
    return luaL_error(L, "sign: generating a P-256 key failed (%d)",
                      (int)status);
  }
  size_t length = 0;
  status = psa_export_key(key, (uint8_t *)out, p256_secret_size, &length);
  psa_destroy_key(key);
  if (status != PSA_SUCCESS || length != p256_secret_size) {
    mbedtls_platform_zeroize(out, p256_secret_size);
    return luaL_error(L, "sign: exporting a P-256 key failed (%d)",
                      (int)status);
  }
  luaL_pushresultsize(&buffer, p256_secret_size);
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
    /* An import refuses a point that is not on the curve. */
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

static const luaL_Reg module[] = {
  {"ed25519_public", sign_ed25519_public},
  {"ed25519", sign_ed25519},
  {"ed25519_verify", sign_ed25519_verify},
  {"p256_secret", sign_p256_secret},
  {"p256_public", sign_p256_public},
  {"p256", sign_p256},
  {"p256_verify", sign_p256_verify},
  {NULL, NULL},
};

int cosmic_open_sign (lua_State *L) {
  luaL_newlib(L, module);
  return 1;
}
