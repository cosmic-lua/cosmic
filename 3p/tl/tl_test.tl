#!/usr/bin/env cosmic
-- ast-grep ignore: test file needs package.path manipulation
local path = require("cosmo.path")

-- Where the pinned tl landed. `cosmic --make fetch` unpacks a pin beside
-- the pin, so the tarball lands whole in this unit's output directory;
-- the Makefile's fetch pipeline stages elsewhere and names it in
-- TEST_DIR, and that arm goes with the Makefile.
--
-- It has to come from the environment or a known path, never a bare
-- `global TEST_DIR`: cosmic injects only _G.arg, so a global reads nil
-- and the prepend below silently resolves the BINARY's embedded tl
-- instead of the staged source this test exists to exercise.
local TEST_DIR = os.getenv("TEST_DIR") or "o/3p/tl"

-- Prepend before requiring, or the embedded tl wins.
package.path = path.join(TEST_DIR, "?.lua") .. ";" .. package.path
local tl = require("tl")

local function test_load_tl()
  assert(tl ~= nil, "failed to load tl")
  assert(type(tl.loader) == "function", "tl.loader should be a function")
  assert(type(tl.generate) == "function", "tl.generate should be a function")
end
test_load_tl()

local function test_parse_simple()
  local result = tl.process_string("local x: number = 1", false, nil, "test.tl")
  assert(result ~= nil, "tl.process_string should return a result")
  assert(result.syntax_errors == nil or #result.syntax_errors == 0, "should have no syntax errors")
end
test_parse_simple()

-- Canary for the 5.4 codegen target: tl.generate's second argument is
-- the target STRING — an options table was once passed here instead,
-- silently regressing every compile to the non-5.4 default, which
-- rejects 5.4-only syntax like <close> attributes  This
-- fails if the target ever stops being honored.
local function test_generate_emits_close_attribute()
  local result = tl.process_string(
    "local x <close> = setmetatable({}, {__close = function() end})\n",
    true, nil, "close_canary.tl")
  assert(result.syntax_errors == nil or #result.syntax_errors == 0,
    "canary snippet should parse")
  local code = tl.generate(result.ast, "5.4")
  assert(code and code:find("<close>", 1, true),
    "5.4 target must emit the <close> attribute")
end
test_generate_emits_close_attribute()
