--- What [`c.check`] keeps of a compile in a memo ([`build.c.inputs`]): it is read again for a file whose inputs have not
--- changed, and never for one whose header has.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local c = require("build.c")

--- The core's C and the headers it includes, which zig parses to a syntax tree, and what bin/zig reads to find or fetch
--- zig, which the system's `sh` runs; the bootstrap cosmic and zig, and the caches zig builds in, which it writes.
Test.policy{
  cpu_features = true,
  profiles = { "system" },
  grants = {
    { path = "bin/cosmic-bootstrap", letters = "r" },
    { path = "bin/zig", letters = "r" },
    { path = "bin/zig.pin", letters = "r" },
    { path = "ci/cosmic-driver.pin", letters = "r" },
    { path = "ci/bootstrap-files.txt", letters = "r" },
    { path = "core/", letters = "r" },
    { path = "vendor/bzip2/", letters = "r" },
    { path = "vendor/cares/include/", letters = "r" },
    { path = "vendor/curl/include/", letters = "r" },
    { path = "vendor/expat/lib/", letters = "r" },
    { path = "vendor/lua/src/", letters = "r" },
    { path = "vendor/mbedtls/include/", letters = "r" },
    { path = "vendor/mbedtls/tf-psa-crypto/", letters = "r" },
    { path = "vendor/miniz/", letters = "r" },
    { path = "vendor/sqlite/", letters = "r" },
    { path = "vendor/xz/src/liblzma/api/", letters = "r" },
    { path = "vendor/yyjson/src/", letters = "r" },
    { path = "/cache/bootstrap", letters = "rwxc" },
    { path = "/cache/zig", letters = "rwxc" },
  },
  env = { "ALL_PROXY", "COSMIC_BOOTSTRAP", "COSMIC_BOOTSTRAP_ATTEMPTS", "COSMIC_BOOTSTRAP_VERIFY",
    "COSMIC_ZIG", "COSMIC_ZIG_CACHE", "COSMIC_ZIG_GLOBAL_CACHE", "CURL_CA_BUNDLE", "HTTPS_PROXY",
    "HTTP_PROXY", "NO_PROXY", "SSL_CERT_DIR", "SSL_CERT_FILE", "all_proxy", "http_proxy",
    "https_proxy", "no_proxy" },
}

local root = assert(Fs.absolute("."))

local header = [[
#include <limits.h>
#include "lauxlib.h"
]]

local broken = header .. [[
static int f(lua_State *L) {
  return (int)luaL_checkinteger(L, 1);
}
]]

local fixed = header .. [[
static int f(lua_State *L) {
  lua_Integer value = luaL_checkinteger(L, 1);
  if (value < 0 || value > INT_MAX) return luaL_error(L, "out of range");
  return (int)value;
}
]]

--- The rules the check finds in `case.c` under `tmp`, with its outcomes kept in `store`.
local function rules_found(tmp: string, store: Sqlite.Handle): {string}
  local outcome = assert(c.check(root, { "case.c" }, tmp, nil, store)[1])
  local found = outcome.findings
  assert(found ~= nil, outcome.trouble)
  local out: mut {string} = {}
  for _, f in ipairs(found) do
    out[#out + 1] = f.file .. ":" .. tostring(f.line) .. " " .. f.rule
  end
  return out
end

--- How many outcomes the store keeps. The check prepares the memo table only for a pinned toolchain, so a store with no
--- table means the check ran without one: the likely cause is a stand-in toolchain variable that leaked into the run.
local function kept(store: Sqlite.Handle): integer
  local rows, why = Sqlite.rows(store, "SELECT count(*) FROM check_memo WHERE kind = 'c'")
  assert(rows ~= nil, tostring(why) .. ": the check kept no memo, which it does for a stand-in toolchain; " ..
      "COSMIC_BOOTSTRAP or COSMIC_ZIG is probably set in this run when it should not be (an entry point, a wrapper or a " ..
      "caller leaking it), or the pinned zig is not installed on this host")
  return assert(math.tointeger(assert(rows[1]):integer(1)))
end

local function test_a_header_changed_since_the_memo_is_checked_afresh(tmp: string)
  -- A fact of this run's environment, not of the host, so no `requires` label fits: a stand-in toolchain keeps no memo.
  for _, name in ipairs({ "COSMIC_BOOTSTRAP", "COSMIC_ZIG" }) do
    local value = Env.get(name)
    if value ~= nil and value ~= "" then
      Test.skip(name .. " is set in this run, so the check uses a stand-in toolchain and keeps no memo")
    end
  end
  local store = assert(Sqlite.open(":memory:", { writable = true }))
  assert(Fs.write(tmp .. "/case.c", '#include "h.h"\n'))
  assert(Fs.write(tmp .. "/h.h", broken))
  local first = rules_found(tmp, store)
  assert(#first == 1, "the violation was not found: " .. table.concat(first, ","))
  -- The same inputs are answered from the memo, the same.
  local again = rules_found(tmp, store)
  assert(table.concat(again, ",") == table.concat(first, ","), table.concat(again, ","))
  -- A header that no longer breaks the rule must not be answered with what it did.
  assert(Fs.write(tmp .. "/h.h", fixed))
  local after = rules_found(tmp, store)
  assert(#after == 0, "a stale answer was served: " .. table.concat(after, ","))
  -- And the first text again is the first answer again.
  assert(Fs.write(tmp .. "/h.h", broken))
  assert(table.concat(rules_found(tmp, store), ",") == table.concat(first, ","))
  -- A run over every file keeps what it used and drops the rest, so the memo does not grow with each edit.
  assert(kept(store) == 1, "the outcome of the text no run used was kept: " .. tostring(kept(store)))
end
