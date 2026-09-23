--- Each rule over a small C file that breaks it and one that keeps it,
--- checked the way `cosmic fix` checks the core: through clang's dump.

local Fs = require("cosmic.fs")
local c = require("build.c")
local rules = require("build.c.rules")

local root = assert(Fs.absolute("."))

--- The findings in `source`, written as `case.c` under `tmp`.
local function findings(tmp: string, source: string): {rules.Finding}
  assert(Fs.write(tmp .. "/case.c", source))
  local outcome = c.check(root, { "case.c" }, tmp)[1]
  assert(outcome.findings ~= nil, outcome.trouble)
  return outcome.findings
end

--- Asserts `found` is exactly one finding of `rule`, on `line`.
local function one(found: {rules.Finding}, rule: string, line: integer)
  local said: {string} = {}
  for _, f in ipairs(found) do said[#said + 1] = f.line .. " " .. f.rule end
  assert(#found == 1 and found[1].rule == rule and found[1].line == line,
    "expected " .. line .. " " .. rule .. ", found: " .. table.concat(said, ", "))
end

local function none(found: {rules.Finding})
  local said: {string} = {}
  for _, f in ipairs(found) do said[#said + 1] = f.line .. " " .. f.rule .. ": " .. f.message end
  assert(#found == 0, "expected nothing, found: " .. table.concat(said, "; "))
end

local header = [[
#include <limits.h>
#include <stdlib.h>
#include "lauxlib.h"
#include "guard.h"
#include "sqlite3.h"
]]

local function test_a_lua_integer_cast_to_int_is_found(tmp: string)
  one(findings(tmp, header .. [[
int f(lua_State *L) {
  return (int)luaL_checkinteger(L, 1);
}
]]), "narrowed-integer", 7)
end

local function test_a_cast_after_a_range_check_is_not(tmp: string)
  none(findings(tmp, header .. [[
int f(lua_State *L) {
  lua_Integer value = luaL_checkinteger(L, 1);
  if (value < 0 || value > INT_MAX) return luaL_error(L, "out of range");
  return (int)value;
}
]]))
end

--- The bug core/surface.c's print once had: luaL_tolstring pushes its
--- string above the buffer, and luaL_addstring then writes over it.
local function test_a_buffer_call_above_a_pushed_value_is_found(tmp: string)
  one(findings(tmp, header .. [[
int f(lua_State *L) {
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  luaL_addstring(&b, luaL_tolstring(L, 1, NULL));
  luaL_pushresult(&b);
  return 1;
}
]]), "above-buffer", 9)
end

local function test_luaL_addvalue_is_the_call_that_may_find_one(tmp: string)
  none(findings(tmp, header .. [[
int f(lua_State *L) {
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  luaL_tolstring(L, 1, NULL);
  luaL_addvalue(&b);
  luaL_addchar(&b, '\n');
  luaL_pushresult(&b);
  return 1;
}
]]))
end

local function test_memory_held_across_a_raise_is_found(tmp: string)
  one(findings(tmp, header .. [[
int f(lua_State *L) {
  char *p = malloc(8);
  if (p == NULL) return luaL_error(L, "no memory");
  lua_pushstring(L, "allocates");
  free(p);
  return 1;
}
]]), "held-across-raise", 9)
end

local function test_memory_released_first_or_guarded_is_not(tmp: string)
  none(findings(tmp, header .. [[
int released(lua_State *L) {
  char *p = malloc(8);
  if (p == NULL) return luaL_error(L, "no memory");
  free(p);
  lua_pushstring(L, "allocates");
  return 1;
}

int guarded(lua_State *L) {
  struct cosmic_guard *guard = cosmic_guard_push(L, free);
  char *p = malloc(8);
  if (p == NULL) return luaL_error(L, "no memory");
  guard->resource = p;
  lua_pushstring(L, "allocates");
  return 1;
}

int quiet(lua_State *L) {
  char *p = malloc(8);
  if (p == NULL) return 0;
  lua_pushinteger(L, lua_gettop(L));
  free(p);
  return 1;
}
]]))
end

--- A branch that returns leaves what it released behind it: the raise
--- after it is still made holding the memory.
local function test_a_release_on_a_returning_branch_does_not_count(tmp: string)
  one(findings(tmp, header .. [[
int f(lua_State *L, int bad) {
  char *p = malloc(8);
  if (p == NULL) return 0;
  if (bad) {
    free(p);
    return 0;
  }
  lua_pushstring(L, "allocates");
  free(p);
  return 1;
}
]]), "held-across-raise", 13)
end

--- SQLite leaves a statement it failed to prepare NULL, so the failure's
--- message holds nothing; a connection it failed to open is still open.
local function test_a_failed_prepare_holds_no_statement(tmp: string)
  none(findings(tmp, header .. [[
int f(lua_State *L, sqlite3 *db) {
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(db, "SELECT 1", -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    lua_pushstring(L, sqlite3_errmsg(db));
    return 1;
  }
  sqlite3_finalize(stmt);
  return 0;
}
]]))
  one(findings(tmp, header .. [[
int f(lua_State *L) {
  sqlite3 *db = NULL;
  int rc = sqlite3_open_v2("x.db", &db, SQLITE_OPEN_READONLY, NULL);
  if (rc != SQLITE_OK) {
    lua_pushstring(L, sqlite3_errmsg(db));
    sqlite3_close_v2(db);
    return 1;
  }
  sqlite3_close_v2(db);
  return 0;
}
]]), "held-across-raise", 10)
end

--- A helper of the file's own that frees what it is handed releases it.
local function test_a_releasing_helper_releases(tmp: string)
  none(findings(tmp, header .. [[
static void drop(char *p) { free(p); }

int f(lua_State *L) {
  char *p = malloc(8);
  if (p == NULL) return 0;
  drop(p);
  lua_pushstring(L, "allocates");
  return 1;
}
]]))
end

local function test_c_clang_cannot_read_is_refused(tmp: string)
  assert(Fs.write(tmp .. "/case.c", "int f(void) { return undeclared; }\n"))
  local outcome = c.check(root, { "case.c" }, tmp)[1]
  assert(outcome.findings == nil)
  assert(outcome.trouble:find("undeclared", 1, true) ~= nil, outcome.trouble)
end

--- A pointer into a string counted from the top is good only while the
--- string is on the stack.
local function test_a_string_read_after_its_pop_is_found(tmp: string)
  one(findings(tmp, header .. [[
#include <string.h>
int f(lua_State *L) {
  const char *s = lua_tostring(L, -1);
  lua_pop(L, 1);
  return (int)strlen(s);
}
]]), "string-after-pop", 10)
  one(findings(tmp, header .. [[
#include <string.h>
int f(lua_State *L) {
  const char *s = luaL_tolstring(L, 1, NULL);
  lua_setfield(L, 2, "x");
  return s[0];
}
]]), "string-after-pop", 10)
end

local function test_a_string_still_on_the_stack_is_not(tmp: string)
  none(findings(tmp, header .. [[
#include <string.h>
int copied(lua_State *L, char *out) {
  const char *s = lua_tostring(L, -1);
  memcpy(out, s, 4);
  lua_pop(L, 1);
  return 0;
}

int below(lua_State *L) {
  const char *s = lua_tostring(L, -1);
  lua_pushinteger(L, 1);
  lua_pop(L, 1);
  return s[0];
}

int argument(lua_State *L) {
  const char *s = luaL_checkstring(L, 1);
  lua_pushinteger(L, 1);
  lua_pop(L, 2);
  return s[0];
}
]]))
end

--- A binding returns what core/syscalls.h declares it does, and a
--- fallible one fails in three values.
local function test_a_binding_returning_another_shape_is_found(tmp: string)
  local found = findings(tmp, header .. [[
#include "syscalls.h"
#include "fail.h"
COSMIC_SYSCALL(getpid, 0) {
  lua_pushinteger(L, 1);
  lua_pushinteger(L, 2);
  return 2;
}

COSMIC_SYSCALL(open, 3) {
  if (lua_gettop(L) == 0) return cosmic_fail(L, EINVAL);
  lua_pushnil(L);
  lua_pushliteral(L, "no");
  return 2;
}
]])
  assert(#found == 2 and found[1].rule == "returned-shape" and found[1].line == 11
    and found[2].rule == "returned-shape" and found[2].line == 18,
    "expected two returned-shape findings, found " .. #found)
end
