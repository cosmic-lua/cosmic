#!/usr/bin/env cosmic

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- The binary under test: TEST_BIN names the directory holding it.
local function bin_path(): string
  return fs.join(os.getenv("TEST_BIN") or ".", "cosmic")
end

-- The harness contract, asserted once so an unwired harness fails here
-- and names itself, rather than as a dozen `command not found: cosmic`
-- further down. TEST_BIN is the whole contract: the directory holding
-- the binaries under test, which is also first on PATH.
local function test_harness_names_the_binary_under_test()
  local bin = os.getenv("TEST_BIN")
  assert(bin ~= nil and bin ~= "", "TEST_BIN should name the binary directory")
end
test_harness_names_the_binary_under_test()

local function test_require_cosmic()
  local cosmic = require("cosmic")
  assert(cosmic ~= nil, "cosmic should not be nil")
  assert(type(cosmic._VERSION) == "string" and cosmic._VERSION ~= "",
    "expected build-injected version string, got " .. tostring(cosmic._VERSION))
  assert(cosmic._VERSION ~= "0.1.0", "version must not be the old hardcoded 0.1.0")
end
test_require_cosmic()

local function test_require_cosmic_spawn()
  local spawn_mod = require("cosmic.child")
  assert(spawn_mod ~= nil, "spawn_mod should not be nil")
  assert(spawn_mod.spawn ~= nil, "spawn_mod.spawn should not be nil")
end
test_require_cosmic_spawn()

local function test_require_cosmic_fs()
  assert(fs ~= nil, "fs should not be nil")
  -- Path functions
  assert(fs.dirname ~= nil, "fs.dirname should not be nil")
  assert(fs.basename ~= nil, "fs.basename should not be nil")
  assert(fs.join ~= nil, "fs.join should not be nil")
  -- Walk functions
  assert(fs.walk ~= nil, "fs.walk should not be nil")
  assert(fs.collect ~= nil, "fs.collect should not be nil")
  assert(fs.collect_all ~= nil, "fs.collect_all should not be nil")
  assert(fs.files ~= nil, "fs.files should not be nil")
end
test_require_cosmic_fs()

local function test_cosmic_main_exists()
  local cosmic = require("cosmic")
  assert(cosmic.main ~= nil, "cosmic.main should not be nil")
  assert(type(cosmic.main) == "function", "expected cosmic.main to be function, got " .. type(cosmic.main))
end
test_cosmic_main_exists()

-- `cosmic.main(fn)` RUNS fn and exits with its code. It does not ask
-- whether its caller is the main chunk, and cannot: `cosmo.is_main()`
-- answers for the chunk that CALLS it, and that chunk is always
-- `cosmic/init.tl`. The guard it used to carry was therefore false
-- every time, so every caller silently did nothing.
--
-- In a child, because the exit IS the contract: asserting it in this
-- process would end the run. The old test called `cosmic.main` inline,
-- so `os.exit(0)` fired inside the call, its assertion never ran, and
-- exit 0 graded as PASS -- a test that could not fail, and one that
-- would have silently swallowed anything appended after it.
local function test_cosmic_main_runs_fn_and_exits_with_its_code()
  local script = fs.join(tmpdir, "cosmic_main_exit.tl")
  assert(fs.write(script, table.concat({
          'local cosmic = require("cosmic")',
          'cosmic.main(function(): number, string',
          '    io.stdout:write("ran\\n")',
          '    return 3, "boom"',
          '  end)',
          'io.stdout:write("returned\\n")',
        }, "\n") .. "\n"))
  local h = check.must(spawn.spawn({bin_path(), script}))
  local r = check.must(h:wait())
  assert(r.code == 3,
    "exits with the code fn returned, got " .. tostring(r.code))
  assert((r.stdout or ""):find("ran", 1, true), "fn runs")
  assert(not (r.stdout or ""):find("returned", 1, true),
    "and main never returns to its caller")
  assert((r.stderr or ""):find("boom", 1, true),
    "the error string goes to stderr, got: " .. tostring(r.stderr))
end
test_cosmic_main_runs_fn_and_exits_with_its_code()
