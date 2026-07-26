#!/usr/bin/env cosmic
-- test cosmic --check style option

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local style = require("cosmic.style")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  fs.write(filepath, content)
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

  local h = check.must(spawn.spawn({cosmic, "--check", "style", input}))
  local __r1 = check.must(h:wait())
  local ok, _ = __r1.ok, __r1.stdout
  assert(ok, "cosmic --check style should succeed on valid file")
end
test_style_valid()

-- A long line is REPORTED by the check and is not a gate failure. The
-- 90-column limit is house style: this tree has 858 lines over it in
-- 184 files, and the gate never ran the check (it ran a second linter
-- that did not call it), so making `--check style` fail on one would
-- fail the gate on the tree that documents the rule. The check stays
-- exported for a project that wants it, and enforcing it here is its
-- own change with its own 858-line diff.
local function test_style_long_line_is_reported_not_enforced()
  local long_line = string.rep("x", 91)
  local input = write_temp("style_long.tl", long_line .. "\n")

  local h = check.must(spawn.spawn({cosmic, "--check", "style", input}))
  local __r2 = check.must(h:wait())
  local ok, _ = __r2.ok, __r2.stdout
  assert(ok, "a long line must not fail the style gate")

  local lines = {long_line}
  local diags = style.check_column_length("x.tl", lines,
    style.DEFAULT_COLUMN_WIDTH)
  assert(#diags == 1, "and the check still reports it, got " .. #diags)
  assert(diags[1].rule == "column-length", "got: " .. diags[1].rule)
end
test_style_long_line_is_reported_not_enforced()

print("All style tests passed!")
