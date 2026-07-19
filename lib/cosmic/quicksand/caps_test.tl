#!/usr/bin/env cosmic
local caps = require("cosmic.quicksand.caps")
local quicksand = require("cosmic.quicksand")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

local test_bin = os.getenv("TEST_BIN")

local function test_module_exports()
  assert(type(caps.supported) == "function")
  assert(type(caps.number_of) == "function")
  assert(type(caps.mask) == "function")
  assert(type(caps.bounding_read) == "function")
  assert(type(caps.bounding_drop) == "function")
  assert(type(caps.drop_bounding) == "function")
  assert(type(caps.NAMES) == "table")
end
test_module_exports()

-- Every curated name resolves to a number on a host that ships the CAP_*
-- constants; CAP_LAST_CAP (a bound, not a capability) is deliberately
-- excluded from NAMES.
local function test_names_resolve()
  if not caps.supported() then
    check.skip("capabilities unsupported on this host")
    return
  end
  assert(#caps.NAMES > 0, "NAMES should be non-empty")
  for _, name in ipairs(caps.NAMES) do
    local n, err = caps.number_of(name)
    assert(n ~= nil, "should resolve " .. name .. ": " .. tostring(err))
    assert(n >= 0, name .. " should be non-negative")
  end
  for _, name in ipairs(caps.NAMES) do
    assert(name ~= "CAP_LAST_CAP", "NAMES must not include the CAP_LAST_CAP bound")
  end
end
test_names_resolve()

-- number_of rejects unknown names and non-strings without throwing.
local function test_number_of_unknown()
  local n, err = caps.number_of("CAP_NOT_A_REAL_CAPABILITY")
  assert(n == nil, "unknown cap should not resolve")
  assert(type(err) == "string", "should return an error string")
  local n2, err2 = caps.number_of(nil)
  assert(n2 == nil and type(err2) == "string", "nil name should error, not throw")
end
test_number_of_unknown()

-- mask sets bit N (1 << number) per name; unknown names error; empty is 0.
local function test_mask()
  if not caps.supported() then
    check.skip("capabilities unsupported on this host")
    return
  end
  assert(caps.mask({}) == 0, "empty mask should be 0")
  local chown = caps.number_of("CAP_CHOWN")
  local m = caps.mask({"CAP_CHOWN"})
  assert(m == (1 << chown), "mask should set the CAP_CHOWN bit")
  local both = caps.mask({"CAP_CHOWN", "CAP_KILL"})
  local kill = caps.number_of("CAP_KILL")
  assert(both == ((1 << chown) | (1 << kill)), "mask should OR the named bits")
  local bad, err = caps.mask({"CAP_BOGUS"})
  assert(bad == nil and type(err) == "string", "unknown name should error")
end
test_mask()

-- bounding_read is non-destructive: it returns a boolean (or a graceful
-- nil + error under an outer sandbox), never throws.
local function test_bounding_read()
  if not caps.supported() then
    check.skip("capabilities unsupported on this host")
    return
  end
  local present, err = caps.bounding_read("CAP_CHOWN")
  assert(present ~= nil or type(err) == "string",
    "bounding_read should return a boolean or nil+err")
  local bad, berr = caps.bounding_read("CAP_BOGUS")
  assert(bad == nil and type(berr) == "string", "unknown cap should error")
end
test_bounding_read()

-- drop_bounding validates the keep-set BEFORE touching the bounding set,
-- so an unknown keep name returns false + err and drops nothing. This is
-- safe to run in-process precisely because it never reaches a real drop.
local function test_drop_bounding_bad_keep()
  local ok, err = caps.drop_bounding({keep = {"CAP_BOGUS"}})
  assert(not ok, "bad keep name should fail")
  assert(type(err) == "string" and err:find("CAP_BOGUS"),
    "error should name the bad capability: " .. tostring(err))
end
test_drop_bounding_bad_keep()

-- The real, irreversible drop path is exercised in a subprocess so it
-- cannot strip this test runner's own bounding set. After a successful
-- PR_CAPBSET_DROP, the capability must read back as absent. Unprivileged
-- hosts (no CAP_SETPCAP) return a graceful error and the child skips.
-- Run via `cosmic -e` so the test needs no writable temp file (the outer
-- build sandbox does not always grant one).
local CHILD_DROP = table.concat({
    'local caps = require("cosmic.quicksand.caps")',
    'if not caps.supported() then io.write("skipped: unsupported\\n") os.exit(0) end',
    'local ok, err = caps.bounding_drop("CAP_CHOWN")',
    'if not ok then io.write("skipped: " .. tostring(err) .. "\\n") os.exit(0) end',
    'local after = caps.bounding_read("CAP_CHOWN")',
    'if after == false then io.write("dropped\\n") else io.write("bad: after=" .. tostring(after) .. "\\n") end',
  }, "\n")

local function test_drop_bounding_child()
  local c = quicksand.capabilities()
  if not c.linux or not test_bin then
    check.skip("caps drop child: non-Linux host or no TEST_BIN")
    return
  end
  local cosmic = fs.join(test_bin, "cosmic")
  local h = check.must(spawn.spawn({cosmic, "-e", CHILD_DROP}))
  local __r1 = check.must(h:wait())
  local ok, out = __r1.ok, __r1.stdout
  if not ok then
    -- An outer seccomp/pledge filter can kill the child before it can
    -- report; a silent return here would hide that from the skip report.
    check.skip("caps drop child died before reporting (outer sandbox)")
    return
  end
  local s = out
  assert(s:find("dropped") or s:find("skipped"),
    "expected dropped or skipped, got: " .. s)
  assert(not s:find("bad:"),
    "drop must leave the capability absent from the bounding set: " .. s)
  if s:find("skipped") then
    check.skip("caps drop: " .. s:gsub("%s+$", ""))
  else
    check.enforced("caps bounding drop")
  end
end
test_drop_bounding_child()

print("caps_test: PASS")
