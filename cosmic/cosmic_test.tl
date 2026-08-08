#!/usr/bin/env cosmic

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local child = require("cosmic.child")

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

local function test_require_cosmic_child()
  local child_mod = require("cosmic.child")
  assert(child_mod ~= nil, "child_mod should not be nil")
  assert(child_mod.start ~= nil, "child_mod.start should not be nil")
end
test_require_cosmic_child()

local function test_require_cosmic_fs()
  assert(fs ~= nil, "fs should not be nil")
  -- Path functions
  assert(fs.dirname ~= nil, "fs.dirname should not be nil")
  assert(fs.basename ~= nil, "fs.basename should not be nil")
  assert(fs.join ~= nil, "fs.join should not be nil")
  -- Walk functions
  assert(fs.visit ~= nil, "fs.visit should not be nil")
  assert(fs.find ~= nil, "fs.find should not be nil")
  assert(fs.find_info ~= nil, "fs.find_info should not be nil")
  assert(fs.find_iter ~= nil, "fs.find_iter should not be nil")
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
-- `cosmic/init.tl`. A guard there is therefore false every time, and
-- every caller silently does nothing.
--
-- In a child, because the exit IS the contract: asserting it in this
-- process would end the run. Calling `cosmic.main` inline instead
-- fires `os.exit(0)` inside the call, so the assertion never runs and
-- exit 0 grades as PASS -- a test that cannot fail, and one that
-- silently swallows anything appended after it.
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
  local h = check.must(child.start({bin_path(), script}))
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

-- main is forgiving about number: any numeric return exits honestly
-- (math.tointeger), a fractional one exits 1 instead of throwing after
-- the program's real work already happened.
local function test_cosmic_main_tolerates_a_fractional_code()
  local script = fs.join(tmpdir, "cosmic_main_frac.tl")
  assert(fs.write(script, table.concat({
          'local cosmic = require("cosmic")',
          'cosmic.main(function(): number, string',
          '    io.stdout:write("ran\\n")',
          '    return 1.5',
          '  end)',
        }, "\n") .. "\n"))
  local h = check.must(child.start({bin_path(), script}))
  local r = check.must(h:wait())
  assert(r.code == 1, "a fractional code should exit 1, got " .. tostring(r.code))
  assert(not (r.stderr or ""):find("exit", 1, true),
    "and never throw from os.exit, got: " .. tostring(r.stderr))
end
test_cosmic_main_tolerates_a_fractional_code()

-- An error return with no code must not exit 0: the error already said
-- the run failed.
local function test_cosmic_main_error_without_code_exits_nonzero()
  local script = fs.join(tmpdir, "cosmic_main_err.tl")
  assert(fs.write(script, table.concat({
          'local cosmic = require("cosmic")',
          'cosmic.main(function(): number, string',
          '    return nil, "boom"',
          '  end)',
        }, "\n") .. "\n"))
  local h = check.must(child.start({bin_path(), script}))
  local r = check.must(h:wait())
  assert(r.code == 1, "error with no code should exit 1, got " .. tostring(r.code))
  assert((r.stderr or ""):find("boom", 1, true),
    "the error string still reaches stderr, got: " .. tostring(r.stderr))
end
test_cosmic_main_error_without_code_exits_nonzero()
