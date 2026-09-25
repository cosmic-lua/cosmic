#include "hash.h"

#include "crypto.h"
#include "lauxlib.h"
#include "psa/crypto.h"

#define HASHER_TYPE "cosmic.hash.hasher"

struct hasher {
  psa_hash_operation_t operation;
  /* Set once `digest` has run, setup failed, or the hasher was closed
   * or collected: every method past that point is an error rather than
   * a crash. */
  int finished;
};

/* The second result of every success: "" in the error slot. */
static int succeeded (lua_State *L) {
  lua_pushliteral(L, "");
  return 2;
}

static struct hasher *checked_hasher (lua_State *L) {
  struct hasher *h = luaL_checkudata(L, 1, HASHER_TYPE);
  if (h->finished) {
    luaL_error(L, "the hasher is finished"); /* throws: a use after the
                                                end is a bug, not a
                                                runtime failure */
  }
  return h;
}

static int hash_hasher (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  psa_algorithm_t alg = cosmic_hash_algorithm(name);
  if (alg == PSA_ALG_NONE) {
    return luaL_argerror(L, 1, "no such digest algorithm");
  }
  struct hasher *h = lua_newuserdatauv(L, sizeof *h, 0);
  h->operation = (psa_hash_operation_t)PSA_HASH_OPERATION_INIT;
  h->finished = 0;
  luaL_setmetatable(L, HASHER_TYPE);

  psa_status_t status = psa_hash_setup(&h->operation, alg);
  if (status != PSA_SUCCESS) {
    h->finished = 1;
    lua_pushnil(L);
    lua_pushstring(L, "the hasher failed to start");
    return 2;
  }
  return succeeded(L);
}

static int hasher_update (lua_State *L) {
  struct hasher *h = checked_hasher(L);
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  psa_status_t status =
      psa_hash_update(&h->operation, (const unsigned char *)data, len);
  if (status != PSA_SUCCESS) {
    psa_hash_abort(&h->operation);
    h->finished = 1;
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
      psa_hash_finish(&h->operation, out, sizeof out, &out_len);
  h->finished = 1;
  if (status != PSA_SUCCESS) {
    lua_pushnil(L);
    lua_pushstring(L, "the hasher failed to finish");
    return 2;
  }
  lua_pushlstring(L, (const char *)out, out_len);
  return succeeded(L);
}

/* `__close` and `__gc` alike: abandons an unfinished digest. A
 * finalizer elsewhere can hand a collected hasher back to Lua, where it
 * is finished like any other. */
static int hasher_gc (lua_State *L) {
  struct hasher *h = luaL_checkudata(L, 1, HASHER_TYPE);
  if (!h->finished) {
    psa_hash_abort(&h->operation);
    h->finished = 1;
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
  {"byte_sum", hash_byte_sum},
  {NULL, NULL},
};

int cosmic_open_hash (lua_State *L) {
  luaL_newmetatable(L, HASHER_TYPE);
  lua_pushcfunction(L, hasher_gc);
  lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, hasher_gc);
  lua_setfield(L, -2, "__close");
  lua_pushstring(L, HASHER_TYPE);
  lua_setfield(L, -2, "__name");
  lua_newtable(L);
  luaL_setfuncs(L, hasher_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, module);
  return 1;
}
