#include "hash.h"

#include "crypto.h"
#include "fail.h"
#include "lauxlib.h"
#include "psa/crypto.h"

#define HASHER_TYPE "cosmic.hash.hasher"

/* One userdata type for a digest and for an HMAC: they answer the same
 * `update` and `digest` and finish the same way. */
struct hasher {
  bool mac;
  union {
    psa_hash_operation_t hash;
    psa_mac_operation_t mac;
  } operation;
  /* Set once `digest` has run, setup failed, or the hasher was closed
   * or collected: every method past that point is an error rather than
   * a crash. */
  bool finished;
};

static struct hasher *checked_hasher (lua_State *L) {
  struct hasher *h = luaL_checkudata(L, 1, HASHER_TYPE);
  if (h->finished) {
    luaL_error(L, "the hasher is finished"); /* throws: a use after the
                                                end is a bug, not a
                                                runtime failure */
  }
  return h;
}

/* Pushes a hasher whose operation is initialized and not yet set up.
 * Unfinished, so the collector abandons it, from the moment it exists. */
static struct hasher *new_hasher (lua_State *L, bool mac) {
  struct hasher *h = lua_newuserdatauv(L, sizeof *h, 0);
  h->mac = mac;
  if (mac) {
    h->operation.mac = (psa_mac_operation_t)PSA_MAC_OPERATION_INIT;
  } else {
    h->operation.hash = (psa_hash_operation_t)PSA_HASH_OPERATION_INIT;
  }
  h->finished = false;
  luaL_setmetatable(L, HASHER_TYPE);
  return h;
}

static void abort_hasher (struct hasher *h) {
  if (h->mac) {
    psa_mac_abort(&h->operation.mac);
  } else {
    psa_hash_abort(&h->operation.hash);
  }
  h->finished = true;
}

/* The hasher on top of the stack, started by `status`: it and "", or nil
 * and a message when the library refused. */
static int started (lua_State *L, struct hasher *h, psa_status_t status) {
  if (status != PSA_SUCCESS) {
    h->finished = true;
    lua_pushnil(L);
    lua_pushstring(L, "the hasher failed to start");
    return 2;
  }
  return cosmic_succeeded(L);
}

static int hash_hasher (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  psa_algorithm_t alg = cosmic_hash_algorithm(name);
  if (alg == PSA_ALG_NONE) {
    return luaL_argerror(L, 1, "no such digest algorithm");
  }
  struct hasher *h = new_hasher(L, false);
  return started(L, h, psa_hash_setup(&h->operation.hash, alg));
}

static int hash_hmac_hasher (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  size_t key_len;
  const char *key = luaL_checklstring(L, 2, &key_len);
  psa_algorithm_t alg = cosmic_hash_algorithm(name);
  if (alg == PSA_ALG_NONE) {
    return luaL_argerror(L, 1, "no such digest algorithm");
  }
  struct hasher *h = new_hasher(L, true);
  return started(L, h, cosmic_hmac_setup(&h->operation.mac, alg, key, key_len));
}

static int hasher_update (lua_State *L) {
  struct hasher *h = checked_hasher(L);
  size_t len;
  const unsigned char *data =
      (const unsigned char *)luaL_checklstring(L, 2, &len);
  psa_status_t status =
      h->mac ? psa_mac_update(&h->operation.mac, data, len)
             : psa_hash_update(&h->operation.hash, data, len);
  if (status != PSA_SUCCESS) {
    abort_hasher(h);
    return luaL_error(L, "the hasher failed"); /* throws: an update failure
                                                   here is not a shape a
                                                   correct caller meets */
  }
  return 0;
}

static int hasher_digest (lua_State *L) {
  struct hasher *h = checked_hasher(L);
  unsigned char out[COSMIC_DIGEST_MAX];
  size_t out_len = 0;
  psa_status_t status =
      h->mac ? psa_mac_sign_finish(&h->operation.mac, out, sizeof out, &out_len)
             : psa_hash_finish(&h->operation.hash, out, sizeof out, &out_len);
  h->finished = true;
  if (status != PSA_SUCCESS) {
    lua_pushnil(L);
    lua_pushstring(L, "the hasher failed to finish");
    return 2;
  }
  lua_pushlstring(L, (const char *)out, out_len);
  return cosmic_succeeded(L);
}

/* `__close` and `__gc` alike: abandons an unfinished digest. A
 * finalizer elsewhere can hand a collected hasher back to Lua, where it
 * is finished like any other. */
static int hasher_gc (lua_State *L) {
  struct hasher *h = luaL_checkudata(L, 1, HASHER_TYPE);
  if (!h->finished) {
    abort_hasher(h);
  }
  return 0;
}

/* The sum of the unsigned bytes of data[first..last], 1-based and
 * inclusive, the whole string by default. A range outside the string
 * raises; an empty one (first == last + 1) sums to 0. */
static int hash_byte_sum (lua_State *L) {
  size_t len;
  const unsigned char *data =
      (const unsigned char *)luaL_checklstring(L, 1, &len);
  lua_Integer first = luaL_optinteger(L, 2, 1);
  lua_Integer last = luaL_optinteger(L, 3, (lua_Integer)len);
  luaL_argcheck(L, first >= 1, 2, "first must be at least 1");
  luaL_argcheck(L, last >= 0 && (lua_Unsigned)last <= len, 3,
                "last must be within the string");
  luaL_argcheck(L, first <= last + 1, 2, "first is past last");
  lua_Integer sum = 0;
  for (lua_Integer i = first; i <= last; i++) sum += data[i - 1];
  lua_pushinteger(L, sum);
  return 1;
}

/* An algorithm nobody has heard of is an argument-shape error and
 * raises; the library refusing a hash it advertises is a bug, and
 * raises too. Neither is a runtime failure a caller could handle. */
static int hashed (lua_State *L, int status, const unsigned char *digest,
                   size_t len) {
  if (status == -1) {
    return luaL_argerror(L, 1, "no such digest algorithm");
  }
  if (status != 0) {
    return luaL_error(L, "the digest failed with status %d", status);
  }
  lua_pushlstring(L, (const char *)digest, len);
  return 1;
}

static int hash_digest (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  unsigned char digest[COSMIC_DIGEST_MAX];
  size_t digest_len = 0;
  int status = cosmic_digest(name, data, len, digest, &digest_len);
  return hashed(L, status, digest, digest_len);
}

static int hash_hmac (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  size_t key_len;
  const char *key = luaL_checklstring(L, 2, &key_len);
  size_t len;
  const char *data = luaL_checklstring(L, 3, &len);
  unsigned char mac[COSMIC_DIGEST_MAX];
  size_t mac_len = 0;
  int status = cosmic_hmac(name, key, key_len, data, len, mac, &mac_len);
  return hashed(L, status, mac, mac_len);
}

static const luaL_Reg hasher_methods[] = {
  {"update", hasher_update},
  {"digest", hasher_digest},
  {NULL, NULL},
};

static const luaL_Reg module[] = {
  {"digest", hash_digest},
  {"hmac", hash_hmac},
  {"hasher", hash_hasher},
  {"hmac_hasher", hash_hmac_hasher},
  {"byte_sum", hash_byte_sum},
  {NULL, NULL},
};

int cosmic_open_hash (lua_State *L) {
  luaL_newmetatable(L, HASHER_TYPE);
  lua_pushcfunction(L, hasher_gc);
  lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, hasher_gc);
  lua_setfield(L, -2, "__close");
  lua_newtable(L);
  luaL_setfuncs(L, hasher_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, module);
  return 1;
}
