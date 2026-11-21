#include "sign.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "lauxlib.h"
#include "monocypher-ed25519.h"
#include "monocypher.h"

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

static const luaL_Reg module[] = {
  {"ed25519_public", sign_ed25519_public},
  {"ed25519", sign_ed25519},
  {"ed25519_verify", sign_ed25519_verify},
  {NULL, NULL},
};

int cosmic_open_sign (lua_State *L) {
  luaL_newlib(L, module);
  return 1;
}
