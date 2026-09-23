/*
 * The checked core's test instruments. The failing allocator wraps the
 * state's own, so memory it hands out and memory the real one hands out
 * are the same memory: it can be put in and taken out mid-run, as Lua's
 * own test suite does with its memory limit. Only growth is refused --
 * Lua requires that freeing and shrinking never fail -- and a refused
 * growth is what raises "not enough memory" wherever Lua asked for it.
 */

#include "testing.h"

#include "lauxlib.h"
#include "sqlite3.h"
#include "store.h"

/* One state per process, and a test worker is its own process. */
static struct {
  lua_Alloc real;
  void *real_ud;
  int installed;
  int failing;
  lua_Integer left;
  lua_Integer refused;
} allocator;

static void *failing_alloc (void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud;
  /* With ptr NULL, osize names the kind of object, not a size. */
  int grows = nsize > 0 && (ptr == NULL || nsize > osize);
  if (grows && allocator.failing) {
    if (allocator.left == 0) {
      allocator.refused++;
      return NULL;
    }
    allocator.left--;
  }
  return allocator.real(allocator.real_ud, ptr, osize, nsize);
}

/* fail_allocations(after): grants the next `after` growing allocations
 * and refuses every one past them, until allow_allocations. */
static int testing_fail_allocations (lua_State *L) {
  lua_Integer after = luaL_checkinteger(L, 1);
  luaL_argcheck(L, after >= 0, 1, "a count of allocations is not negative");
  if (!allocator.installed) {
    allocator.real = lua_getallocf(L, &allocator.real_ud);
    allocator.installed = 1;
    lua_setallocf(L, failing_alloc, NULL);
  }
  allocator.left = after;
  allocator.refused = 0;
  allocator.failing = 1;
  return 0;
}

/* allow_allocations(): grants every allocation again, and answers how
 * many were refused since fail_allocations. */
static int testing_allow_allocations (lua_State *L) {
  allocator.failing = 0;
  lua_pushinteger(L, allocator.refused);
  allocator.refused = 0;
  return 1;
}

/* open_statements(): how many statements are prepared and not yet
 * finalized, across every database the store searches. */
static int testing_open_statements (lua_State *L) {
  lua_Integer open = 0;
  int count = cosmic_store_count(L);
  for (int i = 1; i <= count; i++) {
    sqlite3 *db = cosmic_store_database(L, i);
    for (sqlite3_stmt *s = db == NULL ? NULL : sqlite3_next_stmt(db, NULL);
         s != NULL; s = sqlite3_next_stmt(db, s)) {
      open++;
    }
  }
  lua_pushinteger(L, open);
  return 1;
}

static const luaL_Reg instruments[] = {
  {"fail_allocations", testing_fail_allocations},
  {"allow_allocations", testing_allow_allocations},
  {"open_statements", testing_open_statements},
  {NULL, NULL},
};

int cosmic_open_testing (lua_State *L) {
  luaL_newlib(L, instruments);
  lua_pushliteral(L, COSMIC_CONFIGURATION_NAME);
  lua_setfield(L, -2, "configuration");
  return 1;
}
