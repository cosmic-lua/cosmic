/*
 * The checked core's test instruments. The failing allocator wraps the
 * state's own, so memory it hands out and memory the real one hands out
 * are the same memory: it can be put in and taken out mid-run, as Lua's
 * own test suite does with its memory limit. Only growth is refused --
 * Lua requires that freeing and shrinking never fail -- and a refused
 * growth is what raises "not enough memory" wherever Lua asked for it.
 *
 * The core's own C allocates through core/memory.h, which in this core
 * is the counted heap below: it draws from the same countdown, so one
 * walk of `fail_allocations` refuses a C allocation wherever it would
 * refuse a Lua one, and it keeps the live bytes and blocks, so a test
 * can see a C allocation nothing freed. core/fault.h's fault points are
 * armed here too.
 */

/* This file is the checked core's alone, which build.zig compiles with
 * COSMIC_CHECKED set; a tool that reads it on its own -- `cosmic fix`,
 * the analyzer -- reads it as that core does. */
#ifndef COSMIC_CHECKED
#define COSMIC_CHECKED 1
#endif

#include "testing.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "fault.h"
#include "executable.h"
#include "http.h"
#include "lauxlib.h"
#include "memory.h"
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

/* Whether the next growing allocation, Lua's or the C heap's, is
 * granted: always, unless a countdown is running and has run out. */
static int granted (void) {
  if (!allocator.failing) return 1;
  if (allocator.left == 0) {
    allocator.refused++;
    return 0;
  }
  allocator.left--;
  return 1;
}

static void *failing_alloc (void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud;
  /* With ptr NULL, osize names the kind of object, not a size. */
  int grows = nsize > 0 && (ptr == NULL || nsize > osize);
  if (grows && !granted()) return NULL;
  return allocator.real(allocator.real_ud, ptr, osize, nsize);
}

/* ---- the counted C heap (core/memory.h) ---------------------------- */

/* Each block is preceded by its size, padded to libc's own alignment so
 * the block after it is as aligned as malloc's would be. */
typedef union {
  max_align_t align;
  size_t size;
} block_header;

static struct {
  size_t bytes;
  size_t blocks;
} c_heap;

void *cosmic_malloc (size_t size) {
  if (size > SIZE_MAX - sizeof(block_header) || !granted()) return NULL;
  block_header *h = malloc(sizeof *h + size);
  if (h == NULL) return NULL;
  h->size = size;
  c_heap.bytes += size;
  c_heap.blocks++;
  return h + 1;
}

void *cosmic_calloc (size_t count, size_t size) {
  if (size != 0 && count > SIZE_MAX / size) return NULL;
  void *block = cosmic_malloc(count * size);
  if (block != NULL) memset(block, 0, count * size);
  return block;
}

/* Growth is drawn from the countdown; shrinking, as in Lua's allocator,
 * never fails for want of it. */
void *cosmic_realloc (void *block, size_t size) {
  if (block == NULL) return cosmic_malloc(size);
  block_header *h = (block_header *)block - 1;
  size_t old = h->size;
  if (size > SIZE_MAX - sizeof(block_header)) return NULL;
  if (size > old && !granted()) return NULL;
  block_header *moved = realloc(h, sizeof *h + size);
  if (moved == NULL) return NULL;
  moved->size = size;
  c_heap.bytes = c_heap.bytes - old + size;
  return moved + 1;
}

void cosmic_free (void *block) {
  if (block == NULL) return;
  block_header *h = (block_header *)block - 1;
  c_heap.bytes -= h->size;
  c_heap.blocks--;
  free(h);
}

/* ---- fault points (core/fault.h) ----------------------------------- */

static struct {
  char point[64];
  lua_Integer skip;
  int armed;
} fault;

bool cosmic_fault (const char *point) {
  if (!fault.armed || strcmp(point, fault.point) != 0) return false;
  if (fault.skip > 0) {
    fault.skip--;
    return false;
  }
  fault.armed = 0;
  return true;
}

/* ---- the instruments ----------------------------------------------- */

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

/* c_heap(): the bytes, then the blocks, live on the core's own C heap. */
static int testing_c_heap (lua_State *L) {
  lua_pushinteger(L, (lua_Integer)c_heap.bytes);
  lua_pushinteger(L, (lua_Integer)c_heap.blocks);
  return 2;
}

/* fail_at(point, skip): arms `point` to fail once, after letting `skip`
 * calls through it (0 by default); fail_at() disarms. Either way,
 * answers whether the point armed before was left unfired. */
static int testing_fail_at (lua_State *L) {
  size_t len = 0;
  const char *point = luaL_optlstring(L, 1, NULL, &len);
  lua_Integer skip = luaL_optinteger(L, 2, 0);
  luaL_argcheck(L, point == NULL || (len > 0 && len < sizeof fault.point &&
                                     strlen(point) == len),
                1, "a fault point is a short name");
  luaL_argcheck(L, skip >= 0, 2, "a count of calls is not negative");
  lua_pushboolean(L, fault.armed);
  fault.armed = 0;
  if (point != NULL) {
    memcpy(fault.point, point, len + 1);
    fault.skip = skip;
    fault.armed = 1;
  }
  return 1;
}

/* live_transfers(): how many HTTP transfers hold curl state. */
static int testing_live_transfers (lua_State *L) {
  lua_pushinteger(L, cosmic_http_live_transfers);
  return 1;
}

/* executable_path(room): the running executable's path, as
 * cosmic_executable_path writes it into a buffer of `room` bytes, or
 * nil when it reports that the path does not fit. */
static int testing_executable_path (lua_State *L) {
  char path[4096];
  lua_Integer room = luaL_checkinteger(L, 1);
  luaL_argcheck(L, room >= 1 && room <= (lua_Integer)sizeof path, 1,
                "a room is from 1 to 4096 bytes");
  if (!cosmic_executable_path(path, (size_t)room)) {
    lua_pushnil(L);
  } else {
    lua_pushstring(L, path);
  }
  return 1;
}

/* Every other core registers these names as stand-ins that raise
 * (core/testing.c): edit the two lists together. */
static const luaL_Reg instruments[] = {
  {"fail_allocations", testing_fail_allocations},
  {"allow_allocations", testing_allow_allocations},
  {"open_statements", testing_open_statements},
  {"c_heap", testing_c_heap},
  {"fail_at", testing_fail_at},
  {"live_transfers", testing_live_transfers},
  {"executable_path", testing_executable_path},
  {NULL, NULL},
};

int cosmic_open_testing (lua_State *L) {
  luaL_newlib(L, instruments);
  lua_pushliteral(L, COSMIC_CONFIGURATION_NAME);
  lua_setfield(L, -2, "configuration");
  return 1;
}
