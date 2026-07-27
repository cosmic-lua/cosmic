#!/usr/bin/env cosmic

local check = require("cosmic.check")
local spawn = require("cosmic.child")
local fs = require("cosmic.fs")

-- Where the pinned cosmos products landed. `cosmic --make fetch` unpacks
-- a pin beside the pin, so cosmos.zip's binaries land in this unit's
-- output directory; the Makefile's fetch pipeline stages elsewhere and
-- names it in TEST_DIR, and that arm goes with the Makefile.
--
-- It has to come from the environment or a known path, never a bare
-- `global TEST_DIR`: cosmic injects only _G.arg, so a global reads nil,
-- fs.join(nil, "zip") collapses to "zip", and the test silently
-- exercises whatever the HOST has on PATH instead of the pinned
-- binaries — which passes wherever the host happens to ship them.
local TEST_DIR = os.getenv("TEST_DIR") or "o/3p/cosmos"

local function test_lua()
  local bin = fs.join(TEST_DIR, "lua")
  local handle = check.must(spawn.spawn({bin, "-v"}))
  local __r1 = check.must(handle:wait())
  local ok, got = __r1.ok, __r1.stdout
  assert(ok, "lua -v failed")
  local want = "Lua"
  assert(got:find(want, 1, true), "expected '" .. want .. "' in output, got: " .. got)
end
test_lua()

local function test_zip()
  local bin = fs.join(TEST_DIR, "zip")
  local handle = check.must(spawn.spawn({bin, "--version"}))
  local __r2 = check.must(handle:wait())
  local ok, got = __r2.ok, __r2.stdout
  assert(ok, "zip --version failed")
  local want = "Zip"
  assert(got:find(want, 1, true), "expected '" .. want .. "' in output, got: " .. got)
end
test_zip()
