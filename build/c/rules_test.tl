--- Each rule over a small C file that breaks it and one that keeps it,
--- checked the way `cosmic fix` checks the core: through clang's dump.

local Fs = require("cosmic.fs")
local c = require("build.c")
local observations = require("build.filesystem_observations")
local rules = require("build.c.rules")
local type Declared = require("build.inputs").Declared

--- The core's C and the headers it includes, which zig parses to a syntax
--- tree, and what bin/zig reads to find or fetch zig.
local _inputs: Declared = {
  reads = { "bin/cosmic-bootstrap", "bin/zig", "bin/zig.pin", "ci/cosmic-driver.pin", "core/",
    "vendor/bzip2/", "vendor/cares/include/", "vendor/curl/include/", "vendor/lua/src/",
    "vendor/mbedtls/include/", "vendor/mbedtls/tf-psa-crypto/", "vendor/miniz/", "vendor/sqlite/",
    "vendor/xz/src/liblzma/api/", "vendor/yyjson/src/" },
  env = { "ALL_PROXY", "COSMIC_BOOTSTRAP", "COSMIC_BOOTSTRAP_ATTEMPTS", "COSMIC_BOOTSTRAP_VERIFY",
    "COSMIC_ZIG", "COSMIC_ZIG_CACHE", "COSMIC_ZIG_GLOBAL_CACHE", "CURL_CA_BUNDLE", "HTTPS_PROXY",
    "HTTP_PROXY", "NO_PROXY", "SSL_CERT_DIR", "SSL_CERT_FILE", "all_proxy", "http_proxy",
    "https_proxy", "no_proxy" },
}

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
static int copied(lua_State *L, char *out) {
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

--- The findings of `rule` alone among `found`.
local function only(found: {rules.Finding}, rule: string): {rules.Finding}
  local out: {rules.Finding} = {}
  for _, f in ipairs(found) do
    if f.rule == rule then out[#out + 1] = f end
  end
  return out
end

--- An effect fails with false and a value with nil: execve is declared
--- `boolean` in core/syscalls.h, entropy `string|nil`.
local function test_a_failure_in_the_other_shape_is_found(tmp: string)
  local found = findings(tmp, header .. [[
#include "syscalls.h"
#include "fail.h"
COSMIC_SYSCALL(execve, 3) {
  return cosmic_fail(L, ENOENT);
}

COSMIC_SYSCALL(entropy, 1) {
  if (lua_gettop(L) == 0) return cosmic_fail_effect(L, EINVAL);
  return cosmic_ok(L);
}
]])
  local said: {string} = {}
  for _, f in ipairs(found) do said[#said + 1] = f.line .. " " .. f.rule end
  assert(#found == 3 and found[1].rule == "failure-shape" and found[1].line == 9
    and found[2].line == 13 and found[3].line == 14,
    "expected three failure-shape findings, found: " .. table.concat(said, ", "))
end

--- A binding declared in core/process.h, not core/syscalls.h, is held
--- to its declaration the same way: subreaper is an effect.
local function test_a_process_binding_is_held_to_its_declaration(tmp: string)
  one(findings(tmp, header .. [[
#include "process.h"
#include "fail.h"
COSMIC_SYSCALL(subreaper, 0) {
  return cosmic_fail(L, ENOSYS);
}
]]), "failure-shape", 9)
end

--- A helper of the file that fails in one shape carries it: a wrapper,
--- or a wrapper of one, is seen through.
local function test_a_failure_through_a_helper_is_found(tmp: string)
  local found = findings(tmp, header .. [[
#include "syscalls.h"
#include "fail.h"
static int bad (lua_State *L, int e) { return cosmic_fail(L, e); }
static int worse (lua_State *L, int e) { return bad(L, e); }

COSMIC_SYSCALL(execve, 3) {
  if (lua_gettop(L) == 0) return bad(L, EINVAL);
  return worse(L, ENOENT);
}
]])
  local said: {string} = {}
  for _, f in ipairs(found) do said[#said + 1] = f.line .. " " .. f.rule end
  assert(#found == 2 and found[1].rule == "failure-shape" and found[1].line == 12
    and found[2].line == 13, "found: " .. table.concat(said, ", "))
end

local function test_a_failure_in_its_own_shape_is_not(tmp: string)
  none(findings(tmp, header .. [[
#include "syscalls.h"
#include "fail.h"
static int good (lua_State *L, int e) { return cosmic_fail_effect(L, e); }

COSMIC_SYSCALL(execve, 3) {
  if (lua_gettop(L) == 0) return good(L, EINVAL);
  return cosmic_fail_effect(L, ENOENT);
}

COSMIC_SYSCALL(entropy, 1) {
  if (lua_gettop(L) == 0) return cosmic_fail(L, EINVAL);
  lua_pushliteral(L, "bytes");
  return 1;
}
]]))
end

--- `case.c`'s functions, declared in `case.h`.
local function declared_in_header(tmp: string, declarations: string, source: string):
    {rules.Finding}
  assert(Fs.write(tmp .. "/case.h", declarations))
  return findings(tmp, header .. '#include "case.h"\n' .. source)
end

--- A header's function answering only 0 or 1 -- itself, through a
--- helper of its file, or through a local given only truths -- is a
--- pass or a fail.
local function test_an_int_that_is_a_pass_or_a_fail_is_found(tmp: string)
  local decls = "int literal (int x);\nint helped (int x);\nint held (int x);\n"
  local found = only(declared_in_header(tmp, decls, [[
int literal (int x) {
  if (x < 0) return 0;
  return 1;
}

static int reject (void) { return 0; }

int helped (int x) {
  if (x < 0) return reject();
  return x > 3;
}

int held (int x) {
  int fits = x > 0 && x < 9;
  return fits;
}
]]), "pass-fail-int")
  local said: {string} = {}
  for _, f in ipairs(found) do said[#said + 1] = f.line .. " " .. f.within end
  assert(#found == 3 and found[1].line == 7 and found[2].line == 14
    and found[3].line == 19, "found: " .. table.concat(said, ", "))
end

--- A status is not a truth, nor is a function no header declares, nor
--- one that already returns bool.
local function test_a_status_or_a_bool_is_not(tmp: string)
  local decls = "#include <stdbool.h>\nint status (int x);\nbool truth (int x);\n" ..
    "int fetched (int x);\n"
  none(only(declared_in_header(tmp, decls, [[
int fetch (int *out);

int fetched (int x) {
  int status = 0;
  if (!fetch(&status)) return 0;
  return status;
}

int status (int x) {
  if (x < 0) return -1;
  if (x == 0) return 0;
  return 1;
}

bool truth (int x) {
  return x > 0;
}

static int local_truth (int x) {
  return x > 0;
}

int unused (void) { return local_truth(1) ? 3 : 4; }
]]), "pass-fail-int"))
end

local function test_a_function_returning_one_constant_is_found(tmp: string)
  one(findings(tmp, header .. [[
int install (int *slot, int x) {
  if (x) {
    *slot = x;
    return 0;
  }
  return 0;
}
]]), "constant-return", 6)
end

--- A file's own helper, `main`, and a count of values left on the
--- stack are not flagged: the helper's constant is its file's business,
--- `main`'s is the exit status, and a count is how many values it leaves.
local function test_a_constant_that_says_something_is_not(tmp: string)
  none(findings(tmp, header .. [[
int push_three (lua_State *L, int e) {
  lua_pushinteger(L, e);
  lua_pushinteger(L, e);
  lua_pushinteger(L, e);
  return 3;
}

static int helper (void) { return 0; }

int main (void) { return helper(); }

int count (lua_State *L) {
  lua_pushinteger(L, 1);
  return 1;
}
]]))
end

local function test_a_binding_returning_true_alone_is_found(tmp: string)
  one(findings(tmp, header .. [[
#include "fail.h"
static int close_it (lua_State *L) {
  if (lua_gettop(L) == 0) return luaL_error(L, "nothing to close");
  if (lua_gettop(L) > 1) {
    lua_pushboolean(L, 1);
    return 1;
  }
  return cosmic_ok(L);
}
]]), "true-alone", 7)
end

local function test_a_binding_that_answers_something_is_not(tmp: string)
  none(findings(tmp, header .. [[
static int status (lua_State *L) {
  if (lua_gettop(L) == 0) {
    lua_pushboolean(L, 0);
    return 1;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int close_it (lua_State *L) {
  lua_settop(L, 0);
  return 0;
}
]]))
end

--- The findings of checking `files`, each written under `tmp` from its
--- source, together.
local function checked(tmp: string, sources: {string: string}, files: {string}):
    {rules.Finding}
  for name, source in pairs(sources) do
    assert(Fs.write(tmp .. "/" .. name, source))
  end
  local out: {rules.Finding} = {}
  for _, outcome in ipairs(c.check(root, files, tmp)) do
    assert(outcome.findings ~= nil, outcome.trouble)
    for _, f in ipairs(outcome.findings) do out[#out + 1] = f end
  end
  return out
end

local two_files: {string: string} = {
  ["shared.h"] = "int mine (int x);\nint ours (int x);\n",
  ["a.c"] = [[
#include "shared.h"
int mine (int x) { return x + 2; }
int ours (int x) { return mine(x) * 3; }
static int hidden (int x) { return x - 2; }
int used (void) { return hidden(1); }
]],
  ["b.c"] = [[
#include "shared.h"
int total (void) { return ours(1) + 5; }
]],
}

--- A function its header shares but only its own file refers to is
--- that file's own; one another file calls is shared.
local function test_a_shared_function_only_its_file_uses_is_found(tmp: string)
  local found = only(checked(tmp, two_files, { "a.c", "b.c" }), "single-file")
  one(found, "single-file", 1)
  assert(found[1].file == "shared.h" and found[1].within == "mine",
    found[1].file .. " " .. found[1].within)
end

--- With one file of two checked, what the other refers to is not
--- known, and nothing is said.
local function test_a_partial_check_says_nothing_of_sharing(tmp: string)
  none(only(checked(tmp, two_files, { "a.c" }), "single-file"))
end

--- A syntax tree larger than what is read of one is refused, not
--- checked from wherever the kept part begins.
local function test_a_tree_larger_than_the_limit_is_refused(tmp: string)
  assert(Fs.write(tmp .. "/case.c", header .. "int f(void) { return 0; }\n"))
  local outcome = c.check(root, { "case.c" }, tmp, 4096)[1]
  assert(outcome.findings == nil, "a cut tree was checked")
  assert(outcome.trouble:find("larger than 4096", 1, true) ~= nil, outcome.trouble)
end

--- A file that could not be read leaves what it refers to unknown, so
--- nothing is said of sharing.
local function test_an_unreadable_file_says_nothing_of_sharing(tmp: string)
  local sources: {string: string} = {}
  for name, source in pairs(two_files) do sources[name] = source end
  sources["b.c"] = "int total (void) { return undeclared; }\n"
  for name, source in pairs(sources) do
    assert(Fs.write(tmp .. "/" .. name, source))
  end
  local outcomes = c.check(root, { "a.c", "b.c" }, tmp)
  assert(outcomes[2].findings == nil, "b.c was read")
  none(only(outcomes[1].findings, "single-file"))
end

--- Checking C starts its compilers as declared processes: what names the
--- pinned zig is read, and every header a compiler read but the pinned
--- zig's own -- one beside the file included -- so a test of it stands on
--- them, and a header's change runs it again.
local function test_checking_reads_what_the_compiler_read(tmp: string)
  assert(Fs.write(tmp .. "/extra.h", "int extra(void);\n"))
  local zig_cache = assert(Fs.cache_path("zig"))
  local run = observations.call(function()
    local _ = findings(tmp, header .. '#include "extra.h"\nint f(void) { return 0; }\n')
  end, nil)
  assert(run.passed, run.message)
  local read: {string: boolean} = {}
  local listed: {string: boolean} = {}
  local whole_environment = false
  local started: {string} = {}
  for _, observation in ipairs(run.reads) do
    if observation.kind == "o" then read[observation.path] = true end
    if observation.kind == "d" then listed[observation.path] = true end
    if observation.kind == "e" and observation.path == "\0environ" then
      whole_environment = true
    end
    if observation.kind == "h" or observation.kind == "p" or observation.kind == "x" then
      started[#started + 1] = observation.kind
    end
    assert(not Fs.within(observation.path, zig_cache), observation.path)
  end
  assert(#started > 0, "no compiler was started")
  for _, kind in ipairs(started) do assert(kind == "h", table.concat(started, " ")) end
  for _, path in ipairs({ root .. "/bin/zig.pin", root .. "/build/zig.tl",
                          root .. "/core/guard.h", tmp .. "/extra.h" }) do
    assert(read[path], path .. " was not read")
  end
  -- Where a header was looked for and not found is listed, so one added
  -- there, which the compiler would find first, runs the test again.
  for _, dir in ipairs({ root .. "/core", root .. "/vendor/lua/src", root .. "/vendor/sqlite",
                         root .. "/vendor/mbedtls/include/mbedtls", tmp }) do
    assert(listed[dir], dir .. " was not listed")
  end
  -- Only the variables the compiler is given are read: a key over the
  -- whole environment would change with every `cd`.
  assert(not whole_environment, "the whole environment was read")
end

--- A header whose path holds what a dependency file escapes -- a space, a
--- `#`, a `$` -- is read under its own name.
local function test_an_escaped_header_path_is_read_as_itself(tmp: string)
  assert(Fs.mkdirs(tmp .. "/d $x#y"))
  assert(Fs.write(tmp .. "/d $x#y/h h.h", "int odd(void);\n"))
  local run = observations.call(function()
    local _ = findings(tmp, '#include "d $x#y/h h.h"\nint f(void) { return 0; }\n')
  end, nil)
  assert(run.passed, run.message)
  local read = false
  for _, observation in ipairs(run.reads) do
    if observation.kind == "o" and observation.path == tmp .. "/d $x#y/h h.h" then read = true end
  end
  assert(read, "the header was not read under its own name")
end
