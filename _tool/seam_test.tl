#!/usr/bin/env cosmic
--- reads: o/bootstrap/cosmic
-- The compile seam: runner-mode test files gain the generated tail,
-- every other shape passes through byte-identical, and the tail's
-- 0/2/fail grammar survives the REAL script host (which discards a
-- chunk's return value — the reason the tail exits).

local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local seam = require("_tool.seam")
local teal = require("cosmic.teal")

local tmpdir = os.getenv("TEST_TMPDIR")

local BOOTSTRAP = fs.join("o", "bootstrap", "cosmic")

local RUNNER_SRC = [[
local function test_addition()
  assert(1 + 1 == 2)
end

local function test_strings()
  assert(("x"):rep(2) == "xx")
end
]]

local LEGACY_SRC = [[
local function test_addition()
  assert(1 + 1 == 2)
end
test_addition()
]]

--- Write a fixture and hand back seam.augment's answer for it.
local function augmented(name: string, src: string): seam.Augmented
  local path = fs.join(tmpdir, name)
  assert(fs.write(path, src))
  return check.must(seam.augment(path))
end

-- A legacy file, a helpers-only file, and a non-test path come back
-- byte-identical: the seam speaks only for runner-mode test files.
local function test_other_shapes_pass_through_byte_identical()
  local legacy = augmented("legacy_test.tl", LEGACY_SRC)
  check.equal(legacy.mode, "legacy")
  check.equal(legacy.source, LEGACY_SRC, "legacy bytes untouched")

  local helper = augmented("helpers_test.tl", "local x = 1\nreturn x\n")
  check.equal(helper.mode, "empty")

  local plain = augmented("module.tl", RUNNER_SRC)
  check.equal(plain.mode, "empty", "a non-test path is never classified")
  check.equal(plain.source, RUNNER_SRC)
end

-- A runner-mode file gains exactly the tail: the original lines keep
-- their numbers (the tail joins below the final newline), and the
-- case list is in source order.
local function test_runner_mode_gains_the_tail_below_the_source()
  local aug = augmented("runner_test.tl", RUNNER_SRC)
  check.equal(aug.mode, "runner")
  assert(aug.source:sub(1, #RUNNER_SRC) == RUNNER_SRC,
    "the source prefix is byte-identical, so no line number moves")
  local tail = aug.source:sub(#RUNNER_SRC + 1)
  assert(tail:find("os.exit(require(\"cosmic.test\").main({", 1, true),
    "the tail exits through the runner: " .. tail)
  local first = tail:find("test_addition", 1, true)
  local second = tail:find("test_strings", 1, true)
  assert(first ~= nil and second ~= nil and first < second,
    "cases enroll in source order")
end

-- The augmented source satisfies the strict checker: the tail's calls
-- are the use warnings-as-errors demands, so an uncalled local never
-- fires.
local function test_the_augmented_source_checks_strictly()
  local aug = augmented("runner_check_test.tl", RUNNER_SRC)
  local result = teal.check(aug.source, {chunk_name = "runner_check_test.tl"})
  assert(result.ok and #result.warnings == 0,
    "the checker checks what runs, with no unused-local warning")
end

--- Compile augmented `src`, run it under the pinned bootstrap, and
--- hand back the child's exit code — the grammar testrun reads.
local function exit_of(name: string, src: string, filter?: string): integer
  local aug = augmented(name, src)
  local result = teal.compile(aug.source, {strict = true, chunk_name = name})
  assert(result.ok, "the augmented source compiles strictly")
  local lua_path = fs.join(tmpdir, (name:gsub("%.tl$", ".lua")))
  assert(fs.write(lua_path, check.must(result.code)))
  -- Never a silent skip: a missing bootstrap means the grammar below
  -- was never exercised (same rule as _perf/skew_test.tl).
  assert(fs.is_file(BOOTSTRAP), BOOTSTRAP ..
    " is missing; run bin/cosmic once (any verb) to land it")
  local vars: {string: string} = {COSMIC_COVERAGE = "0"}
  if filter ~= nil then
    vars["COSMIC_TEST_FILTER"] = filter
  end
  local r = check.must(child.run({BOOTSTRAP, lua_path},
      {env = env.list({set = vars})}))
  return r.code
end

-- The 0/2/fail grammar through the real host: a passing pair exits 0,
-- a failing case exits nonzero, and a filter that matches nothing
-- exits 2 — the exits the tail exists to deliver, because the host
-- discards a chunk's return value.
local function test_the_tail_delivers_the_exit_grammar()
  check.equal(exit_of("grammar_pass_test.tl", RUNNER_SRC), 0,
    "all passing exits 0")
  check.equal(exit_of("grammar_fail_test.tl", [[
local function test_broken()
  assert(1 == 2, "meant to fail")
end
]]), 1, "a failing case exits nonzero")
  check.equal(exit_of("grammar_skip_test.tl", RUNNER_SRC, "no_such_case"), 2,
    "a filter matching nothing exits 2")
end

print("all compile seam tests passed")
