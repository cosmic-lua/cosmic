#include "hash.h"

#include <stdint.h>

#include "check.h"
#include "crypto.h"
#include "fail.h"
#include "lauxlib.h"
#include "psa/crypto.h"

#define HASHER_TYPE "cosmic.hash.hasher"

/* One userdata type for a digest and for an HMAC (`keyed`): they answer the same
 * `update` and `digest` and finish the same way. */
struct hasher {
  bool keyed;
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
    luaL_error(L, "hash: the hasher is finished"); /* throws: a use after the
                                                end is a bug, not a
                                                runtime failure */
  }
  return h;
}

/* Pushes a hasher whose operation is initialized and not yet set up.
 * Unfinished, so the collector abandons it, from the moment it exists. */
static struct hasher *new_hasher (lua_State *L, bool keyed) {
  struct hasher *h = lua_newuserdatauv(L, sizeof *h, 0);
  h->keyed = keyed;
  if (keyed) {
    h->operation.mac = (psa_mac_operation_t)PSA_MAC_OPERATION_INIT;
  } else {
    h->operation.hash = (psa_hash_operation_t)PSA_HASH_OPERATION_INIT;
  }
  h->finished = false;
  luaL_setmetatable(L, HASHER_TYPE);
  return h;
}

static void abort_hasher (struct hasher *h) {
  if (h->keyed) {
    psa_mac_abort(&h->operation.mac);
  } else {
    psa_hash_abort(&h->operation.hash);
  }
  h->finished = true;
}

/* Answers for the hasher on top of the stack, set up with `status`: the
 * hasher and "" on success, otherwise nil and a message. */
static int started (lua_State *L, struct hasher *h, psa_status_t status) {
  if (status != PSA_SUCCESS) {
    h->finished = true;
    lua_pushnil(L);
    lua_pushstring(L, "hash: the hasher failed to start");
    return 2;
  }
  return cosmic_succeeded(L);
}

static int hash_hasher (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  psa_algorithm_t alg = cosmic_hash_algorithm(name);
  if (alg == PSA_ALG_NONE) {
    return luaL_error(L, "hash: no such digest algorithm");
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
    return luaL_error(L, "hash: no such digest algorithm");
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
      h->keyed ? psa_mac_update(&h->operation.mac, data, len)
             : psa_hash_update(&h->operation.hash, data, len);
  if (status != PSA_SUCCESS) {
    abort_hasher(h);
    return luaL_error(L, "hash: the hasher failed"); /* throws: an update failure
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
      h->keyed ? psa_mac_sign_finish(&h->operation.mac, out, sizeof out, &out_len)
             : psa_hash_finish(&h->operation.hash, out, sizeof out, &out_len);
  h->finished = true;
  if (status != PSA_SUCCESS) {
    lua_pushnil(L);
    lua_pushstring(L, "hash: the hasher failed to finish");
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
    return luaL_error(L, "hash: no such digest algorithm");
  }
  if (status != 0) {
    return luaL_error(L, "hash: the digest failed with status %d", status);
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

/* SipHash (Aumasson and Bernstein, "SipHash: a fast short-input PRF") as
 * its reference implementation computes it: `c` compression rounds per
 * 8-byte word, `d` finalization rounds, and an 8- or 16-byte tag. */
static uint64_t load_le64 (const unsigned char *p) {
  uint64_t x = 0;
  for (int i = 7; i >= 0; i--) x = (x << 8) | p[i];
  return x;
}

static void store_le64 (unsigned char *p, uint64_t x) {
  for (int i = 0; i < 8; i++) {
    p[i] = (unsigned char)(x & 0xff);
    x >>= 8;
  }
}

static uint64_t rotl64 (uint64_t x, int b) {
  return (x << b) | (x >> (64 - b));
}

static void sip_rounds (uint64_t v[4], int rounds) {
  for (int i = 0; i < rounds; i++) {
    v[0] += v[1]; v[1] = rotl64(v[1], 13); v[1] ^= v[0]; v[0] = rotl64(v[0], 32);
    v[2] += v[3]; v[3] = rotl64(v[3], 16); v[3] ^= v[2];
    v[0] += v[3]; v[3] = rotl64(v[3], 21); v[3] ^= v[0];
    v[2] += v[1]; v[1] = rotl64(v[1], 17); v[1] ^= v[2]; v[2] = rotl64(v[2], 32);
  }
}

static int hash_siphash (lua_State *L) {
  size_t key_len;
  const unsigned char *key =
      (const unsigned char *)luaL_checklstring(L, 1, &key_len);
  size_t len;
  const unsigned char *data =
      (const unsigned char *)luaL_checklstring(L, 2, &len);
  int c = cosmic_optint(L, 3, 2);
  int d = cosmic_optint(L, 4, 4);
  int size = cosmic_optint(L, 5, 8);
  luaL_argcheck(L, key_len == 16, 1, "the key must be 16 bytes");
  luaL_argcheck(L, c >= 1 && c <= 64, 3, "compression rounds must be 1 to 64");
  luaL_argcheck(L, d >= 1 && d <= 64, 4, "finalization rounds must be 1 to 64");
  luaL_argcheck(L, size == 8 || size == 16, 5, "the tag must be 8 or 16 bytes");
  uint64_t k0 = load_le64(key);
  uint64_t k1 = load_le64(key + 8);
  uint64_t v[4] = {
    k0 ^ UINT64_C(0x736f6d6570736575),
    k1 ^ UINT64_C(0x646f72616e646f6d),
    k0 ^ UINT64_C(0x6c7967656e657261),
    k1 ^ UINT64_C(0x7465646279746573),
  };
  if (size == 16) v[1] ^= 0xee;
  size_t whole = len - len % 8;
  for (size_t at = 0; at < whole; at += 8) {
    uint64_t m = load_le64(data + at);
    v[3] ^= m;
    sip_rounds(v, c);
    v[0] ^= m;
  }
  uint64_t b = (uint64_t)len << 56;
  for (size_t i = 0; i < len % 8; i++) b |= (uint64_t)data[whole + i] << (8 * i);
  v[3] ^= b;
  sip_rounds(v, c);
  v[0] ^= b;
  v[2] ^= size == 16 ? 0xee : 0xff;
  sip_rounds(v, d);
  unsigned char tag[16];
  store_le64(tag, v[0] ^ v[1] ^ v[2] ^ v[3]);
  if (size == 16) {
    v[1] ^= 0xdd;
    sip_rounds(v, d);
    store_le64(tag + 8, v[0] ^ v[1] ^ v[2] ^ v[3]);
  }
  lua_pushlstring(L, (const char *)tag, (size_t)size);
  return 1;
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
  {"siphash", hash_siphash},
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
