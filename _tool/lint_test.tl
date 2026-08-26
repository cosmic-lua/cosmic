#!/usr/bin/env cosmic
-- test cosmic --check lint option

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local child = require("cosmic.child")
local style = require("_tool.lint")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  assert(fs.write(filepath, content))
  return filepath
end

-- Valid short file: should pass
local function test_style_valid()
  local input = write_temp("style_valid.tl", [[
local function add(a: number, b: number): number
  return a + b
end
add(1, 2)
]])

  local h = check.must(child.start({cosmic, "--check", "lint", input}))
  local __r1 = check.must(h:wait())
  local ok, _ = __r1.ok, __r1.stdout
  assert(ok, "cosmic --check lint should succeed on valid file")
end
test_style_valid()

-- A long line is REPORTED by the check and is not a gate failure. The
-- 90-column limit is house style: this tree has roughly 800+ lines
-- over it across ~180 files, and the gate never ran the check (it ran
-- a second linter that did not call it), so making `--check lint` fail
-- on one would fail the gate on the tree that documents the rule. The
-- check stays exported for a project that wants it, and enforcing it
-- here is its own change with its own multi-hundred-line diff.
local function test_style_long_line_is_not_enforced()
  -- Column width is house style (90 columns), not a gate: this test
  -- only confirms a long line does not fail `--check lint`.
  local long_line = string.rep("x", 91)
  local input = write_temp("style_long.tl", long_line .. "\n")

  local h = check.must(child.start({cosmic, "--check", "lint", input}))
  local __r2 = check.must(h:wait())
  local ok, _ = __r2.ok, __r2.stdout
  assert(ok, "a long line must not fail the style gate")
end
test_style_long_line_is_not_enforced()

-- The justification-marker reader, shared by the two conventions that
-- demand a written reason beside a site: `-- cast:` and `-- assert:`.

local function test_is_justified_reads_the_line_and_the_one_above()
  local lines: {string} = {
    "local d = x as Rec -- cast: record union after guard",
    "-- cast: from any",
    "local o = decode(s) as {string: any}",
    "local n = y as Rec",
  }
  check.truthy(style.is_justified(lines, 1, "cast"), "trailing reason counts")
  check.truthy(style.is_justified(lines, 3, "cast"), "the line above counts")
  check.truthy(not style.is_justified(lines, 4, "cast"),
    "line 3 carries no marker, so line 4 is unjustified")
end
test_is_justified_reads_the_line_and_the_one_above()

local function test_is_justified_discriminates_by_marker()
  local lines: {string} = {
    "local t = assert(now()) -- assert: CLOCK_REALTIME always resolves",
    "local d = x as Rec -- cast: record union after guard",
  }
  check.truthy(style.is_justified(lines, 1, "assert"), "its own marker counts")
  check.truthy(not style.is_justified(lines, 1, "cast"),
    "an assert reason does not license a cast")
  check.truthy(not style.is_justified(lines, 2, "assert"),
    "and a cast reason does not license an assert")
end
test_is_justified_discriminates_by_marker()

local function test_is_justified_demands_a_reason()
  local lines: {string} = {"local d = x as Rec -- cast:"}
  check.truthy(not style.is_justified(lines, 1, "cast"),
    "a bare marker with nothing after it justifies nothing")
end
test_is_justified_demands_a_reason()

print("All style tests passed!")
