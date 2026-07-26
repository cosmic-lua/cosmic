#!/usr/bin/env cosmic
-- test cosmic --check-style option

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

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

  local h = check.must(spawn.spawn({cosmic, "--check-style", input}))
  local __r1 = check.must(h:wait())
  local ok, _ = __r1.ok, __r1.stdout
  assert(ok, "cosmic --check-style should succeed on valid file")
end
test_style_valid()

-- File with a long line (> 90 cols): should fail
local function test_style_long_line()
  local long_line = string.rep("x", 91)
  local input = write_temp("style_long.tl", long_line .. "\n")

  local h = check.must(spawn.spawn({cosmic, "--check-style", input}))
  local __r2 = check.must(h:wait())
  local ok, _ = __r2.ok, __r2.stdout
  assert(not ok, "cosmic --check-style should fail on file with long line")
end
test_style_long_line()

-- File with function not called immediately after definition: should fail
-- The rule is 'call-after-define': each test_* function must be called right
-- after its definition so failures point to the right function.
local function test_style_call_after_define()
  local input = write_temp("style_order.tl", [[
local function foo()
  return 1
end
local function bar()
  return 2
end
foo()
bar()
]])

  local h = check.must(spawn.spawn({cosmic, "--check-style", input}))
  local __r3 = check.must(h:wait())
  local ok, _ = __r3.ok, __r3.stdout
  assert(not ok, "cosmic --check-style should fail when function not called immediately after definition")
end
test_style_call_after_define()

-- A function body containing if/for/do blocks must not fool the
-- closing-end detection (audit §5.2: style.tl had drifted from its
-- tested twin _build/lint.tl, which counts all block openers).
-- Exercised through the CLI so bin/make lint and cosmic --check-style
-- are proven to agree on the same input.
local function test_style_block_scopes_in_body()
  local input = write_temp("style_blocks.tl", [[
local function foo()
  if true then
    local x = 1
  end
  for i = 1, 2 do
    local y = i
  end
  do
    local z = 3
  end
  return 1
end
foo()
]])

  local h = check.must(spawn.spawn({cosmic, "--check-style", input}))
  local __r5 = check.must(h:wait())
  local ok, _ = __r5.ok, __r5.stdout
  assert(ok, "block scopes inside a body must not trip call-after-define")
end
test_style_block_scopes_in_body()

-- The same block-heavy body with the call missing must still fail.
local function test_style_block_scopes_missing_call()
  local input = write_temp("style_blocks_bad.tl", [[
local function foo()
  if true then
    local x = 1
  end
end
local other = 1
]])

  local h = check.must(spawn.spawn({cosmic, "--check-style", input}))
  local __r6 = check.must(h:wait())
  local ok, _ = __r6.ok, __r6.stdout
  assert(not ok, "missing call must still fail with block scopes in the body")
end
test_style_block_scopes_missing_call()

-- Missing file: should fail
local function test_style_missing_file()
  local h = check.must(spawn.spawn({cosmic, "--check-style", "/nonexistent/file.tl"}))
  local __r4 = check.must(h:wait())
  local ok, _ = __r4.ok, __r4.stdout
  assert(not ok, "cosmic --check-style should fail on missing file")
end
test_style_missing_file()

-- An empty findings list must mean "read, and clean" -- never "could
-- not open". Returning `{}` for a file it could not open made a lint
-- sweep pass over a file it never checked, which is a fail-open in a
-- gate whose job is "every file obeys the caps". The module is public
-- API, so every downstream caller inherited the trap.
local function test_lint_file_reports_what_it_cannot_read()
  local style = require("cosmic.style")
  local missing = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "not-here.tl")
  fs.rmrf(missing)
  local diagnostics, err = style.lint_file(missing)
  assert(not diagnostics, "an unreadable path must not report clean")
  assert(err and #err > 0, "and must say why, got: " .. tostring(err))
end
test_lint_file_reports_what_it_cannot_read()

print("All style tests passed!")
