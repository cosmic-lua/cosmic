#include "hash.h"

#include "crypto.h"
#include "lauxlib.h"
#include "psa/crypto.h"

#define HASHER_TYPE "cosmic.hash.hasher"

struct hasher {
  psa_hash_operation_t operation;
  /* Set once `digest` has run, or setup failed: every method past that
   * point is an error rather than a crash. */
  int finished;
};

static struct hasher *checked_hasher(lua_State *L) {
  struct hasher *h = luaL_checkudata(L, 1, HASHER_TYPE);
  if (h->finished) {
    luaL_error(L, "the hasher is finished");
  }
  return h;
}

static int hash_hasher(lua_State *L) {
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
  return 1;
}

static int hasher_update(lua_State *L) {
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

static int hasher_digest(lua_State *L) {
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
  return 1;
}

static int hasher_gc(lua_State *L) {
  struct hasher *h = luaL_checkudata(L, 1, HASHER_TYPE);
  if (!h->finished) {
    psa_hash_abort(&h->operation);
    h->finished = 1;
  }
  return 0;
}

static const luaL_Reg hasher_methods[] = {
    {"update", hasher_update},
    {"digest", hasher_digest},
    {NULL, NULL},
};

static const luaL_Reg module[] = {
    {"hasher", hash_hasher},
    {NULL, NULL},
};

int cosmic_open_hash(lua_State *L) {
  luaL_newmetatable(L, HASHER_TYPE);
  lua_pushcfunction(L, hasher_gc);
  lua_setfield(L, -2, "__gc");
  lua_pushstring(L, HASHER_TYPE);
  lua_setfield(L, -2, "__name");
  lua_newtable(L);
  luaL_setfuncs(L, hasher_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, module);
  return 1;
}
