#include "cipher.h"

#include <stdlib.h>
#include <string.h>

#include "fail.h"
#include "lauxlib.h"
#include "mbedtls/platform_util.h"
#include "psa/crypto.h"

/* The tag every algorithm here appends to its ciphertext, in bytes. */
#define TAG_LENGTH 16

/* An X25519 private key, public key and shared secret alike, in bytes. */
#define X25519_LENGTH 32

/* What an algorithm name names. The one table of them: an algorithm
 * joins by a row here. */
struct aead {
  const char *name;
  psa_algorithm_t alg;
  psa_key_type_t key_type;
  size_t key_length;
  size_t nonce_length;
};

static const struct aead aeads[] = {
  {"chacha20-poly1305", PSA_ALG_CHACHA20_POLY1305, PSA_KEY_TYPE_CHACHA20, 32,
    12},
};

_Noreturn static void no_such_algorithm (lua_State *L) {
  luaL_error(L, "cipher: no such algorithm");
  abort(); /* luaL_error never returns */
}

/* The arguments `seal` and `open` share: the algorithm argument 1 names,
 * with the key (argument 2) and the nonce (argument 3) it takes. A name
 * that is no algorithm, or a key or nonce of another length, raises. */
static const struct aead *checked_aead (lua_State *L, const unsigned char **key,
                                        const unsigned char **nonce) {
  const char *name = luaL_checkstring(L, 1);
  size_t key_length;
  size_t nonce_length;
  *key = (const unsigned char *)luaL_checklstring(L, 2, &key_length);
  *nonce = (const unsigned char *)luaL_checklstring(L, 3, &nonce_length);
  const struct aead *aead = NULL;
  for (size_t i = 0; i < sizeof aeads / sizeof *aeads; i++) {
    if (strcmp(aeads[i].name, name) == 0) {
      aead = &aeads[i];
    }
  }
  if (aead == NULL) {
    no_such_algorithm(L);
  }
  luaL_argcheck(L, key_length == aead->key_length, 2,
                "the key is not the algorithm's length");
  luaL_argcheck(L, nonce_length == aead->nonce_length, 3,
                "the nonce is not the algorithm's length");
  return aead;
}

/* Imports `key` into `*id` for one use of `aead`, to encrypt or to
 * decrypt as `usage` says. The caller destroys it. */
static psa_status_t import_aead_key (const struct aead *aead,
                                     psa_key_usage_t usage,
                                     const unsigned char *key,
                                     psa_key_id_t *id) {
  psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
  psa_set_key_type(&attributes, aead->key_type);
  psa_set_key_usage_flags(&attributes, usage);
  psa_set_key_algorithm(&attributes, aead->alg);
  return psa_import_key(&attributes, key, aead->key_length, id);
}

/* A key lives in the library's own slot for exactly one computation:
 * imported, used, destroyed, and all of it between two calls into Lua,
 * so that no raise finds the slot taken. The output is a userdata made
 * before the key is imported, for the same reason. */

static int cipher_seal (lua_State *L) {
  const unsigned char *key;
  const unsigned char *nonce;
  const struct aead *aead = checked_aead(L, &key, &nonce);
  size_t length;
  const unsigned char *plaintext =
      (const unsigned char *)luaL_checklstring(L, 4, &length);
  size_t aad_length = 0;
  const unsigned char *aad =
      (const unsigned char *)luaL_optlstring(L, 5, "", &aad_length);
  size_t size = length + TAG_LENGTH;
  unsigned char *sealed = lua_newuserdatauv(L, size, 0);
  size_t sealed_length = 0;
  psa_key_id_t id = 0;
  psa_status_t status = import_aead_key(aead, PSA_KEY_USAGE_ENCRYPT, key, &id);
  if (status == PSA_SUCCESS) {
    status = psa_aead_encrypt(id, aead->alg, nonce, aead->nonce_length, aad,
                              aad_length, plaintext, length, sealed, size,
                              &sealed_length);
    psa_destroy_key(id);
  }
  if (status != PSA_SUCCESS) {
    /* throws: with the arguments checked, what is left is the library
     * out of memory or refusing what it advertises */
    return luaL_error(L, "cipher: sealing failed with status %d", (int)status);
  }
  lua_pushlstring(L, (const char *)sealed, sealed_length);
  return 1;
}

static int cipher_open (lua_State *L) {
  const unsigned char *key;
  const unsigned char *nonce;
  const struct aead *aead = checked_aead(L, &key, &nonce);
  size_t length;
  const unsigned char *sealed =
      (const unsigned char *)luaL_checklstring(L, 4, &length);
  size_t aad_length = 0;
  const unsigned char *aad =
      (const unsigned char *)luaL_optlstring(L, 5, "", &aad_length);
  if (length < TAG_LENGTH) {
    lua_pushnil(L);
    lua_pushstring(L, "cipher: the sealed message is shorter than its tag");
    return 2;
  }
  size_t size = length - TAG_LENGTH;
  unsigned char *plaintext = lua_newuserdatauv(L, size, 0);
  size_t plaintext_length = 0;
  psa_key_id_t id = 0;
  psa_status_t status = import_aead_key(aead, PSA_KEY_USAGE_DECRYPT, key, &id);
  if (status == PSA_SUCCESS) {
    status = psa_aead_decrypt(id, aead->alg, nonce, aead->nonce_length, aad,
                              aad_length, sealed, length, plaintext, size,
                              &plaintext_length);
    psa_destroy_key(id);
  }
  if (status != PSA_SUCCESS) {
    /* Nothing of a message that failed is left where the collector
     * frees it. */
    mbedtls_platform_zeroize(plaintext, size);
  }
  if (status == PSA_ERROR_INVALID_SIGNATURE) {
    lua_pushnil(L);
    lua_pushstring(L, "cipher: the sealed message does not authenticate");
    return 2;
  }
  if (status != PSA_SUCCESS) {
    return luaL_error(L, "cipher: opening failed with status %d", (int)status);
  }
  lua_pushlstring(L, (const char *)plaintext, plaintext_length);
  return cosmic_succeeded(L);
}

/* Imports the X25519 private key at argument 1 into `*id`, raising on
 * one that is not 32 bytes. The library clamps it as RFC 7748 says. The
 * caller destroys it. */
static psa_status_t import_x25519_key (lua_State *L, psa_key_id_t *id) {
  size_t length;
  const unsigned char *private =
      (const unsigned char *)luaL_checklstring(L, 1, &length);
  luaL_argcheck(L, length == X25519_LENGTH, 1,
                "the private key must be 32 bytes");
  psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
  psa_set_key_type(&attributes,
                   PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_MONTGOMERY));
  psa_set_key_bits(&attributes, 255);
  psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_DERIVE);
  psa_set_key_algorithm(&attributes, PSA_ALG_ECDH);
  return psa_import_key(&attributes, private, length, id);
}

static int cipher_x25519_public (lua_State *L) {
  unsigned char public[X25519_LENGTH];
  size_t public_length = 0;
  psa_key_id_t id = 0;
  psa_status_t status = import_x25519_key(L, &id);
  if (status == PSA_SUCCESS) {
    status = psa_export_public_key(id, public, sizeof public, &public_length);
    psa_destroy_key(id);
  }
  if (status != PSA_SUCCESS) {
    return luaL_error(L, "cipher: the public key failed with status %d",
                      (int)status);
  }
  lua_pushlstring(L, (const char *)public, public_length);
  return 1;
}

static int cipher_x25519 (lua_State *L) {
  size_t peer_length;
  const unsigned char *peer =
      (const unsigned char *)luaL_checklstring(L, 2, &peer_length);
  luaL_argcheck(L, peer_length == X25519_LENGTH, 2,
                "the peer's public key must be 32 bytes");
  /* The secret is computed into a userdata, never onto the C stack,
   * which a raise from the push below would unwind unwiped. */
  unsigned char *secret = lua_newuserdatauv(L, X25519_LENGTH, 0);
  size_t secret_length = 0;
  psa_key_id_t id = 0;
  psa_status_t status = import_x25519_key(L, &id);
  if (status == PSA_SUCCESS) {
    status = psa_raw_key_agreement(PSA_ALG_ECDH, id, peer, peer_length, secret,
                                   X25519_LENGTH, &secret_length);
    psa_destroy_key(id);
  }
  if (status == PSA_SUCCESS) {
    /* The library refuses a point of low order itself. The contract
     * that an all-zero secret is never answered is held here too, so
     * that it does not rest on which of the library's paths computed
     * it. Every byte is read, with no branch on one. */
    volatile unsigned char any = 0;
    for (size_t i = 0; i < secret_length; i++) any |= secret[i];
    if (any == 0) {
      status = PSA_ERROR_INVALID_ARGUMENT;
    }
  }
  if (status == PSA_ERROR_INVALID_ARGUMENT) {
    /* The lengths are checked above, so the argument refused is the
     * peer's point. */
    lua_pushnil(L);
    lua_pushstring(L, "cipher: the peer's public key is a point of low order");
    return 2;
  }
  if (status != PSA_SUCCESS) {
    return luaL_error(L, "cipher: the key agreement failed with status %d",
                      (int)status);
  }
  lua_pushlstring(L, (const char *)secret, secret_length);
  mbedtls_platform_zeroize(secret, X25519_LENGTH);
  return cosmic_succeeded(L);
}

static const luaL_Reg module[] = {
  {"seal", cipher_seal},
  {"open", cipher_open},
  {"x25519_public", cipher_x25519_public},
  {"x25519", cipher_x25519},
  {NULL, NULL},
};

int cosmic_open_cipher (lua_State *L) {
  luaL_newlib(L, module);
  return 1;
}
