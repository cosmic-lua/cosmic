#!/usr/bin/env cosmic
-- Test discovery. One lexer walk classifies a test file — legacy
-- (every top-level test_* self-called), runner (none called, and no
-- case name referenced anywhere else), mixed (the D29 shape that must
-- never pass), empty (no test_* at all) — and yields the ordered case
-- list.

local check = require("cosmic.check")
local discover = require("_tool.discover")

--- Split the way lint_file splits, so fixtures see the same lines.
local function lines_of(src: string): {string}
  local out: {string} = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  return out
end

local function walk(src: string): discover.Discovery
  return discover.discover("x_test.tl", src, lines_of(src))
end

local function test_an_all_called_file_is_legacy_in_order()
  local src = "local function test_b()\n  return 2\nend\ntest_b()\n\n"
  .. "local function test_a()\n  return 1\nend\ntest_a()\n"
  local d = walk(src)
  check.equal(d.mode, "legacy")
  check.equal(#d.cases, 2, "two cases discovered")
  check.equal(d.cases[1].name, "test_b", "source order, not name order")
  check.equal(d.cases[2].name, "test_a")
  check.equal(d.cases[1].line, 1)
  check.truthy(d.cases[1].called and d.cases[2].called)
end
test_an_all_called_file_is_legacy_in_order()

local function test_a_none_called_file_is_runner()
  local src = "local function test_a()\n  return 1\nend\n\n"
  .. "local function test_b()\n  return 2\nend\n"
  local d = walk(src)
  check.equal(d.mode, "runner")
  check.equal(#d.cases, 2)
  check.truthy(not d.cases[1].called and not d.cases[2].called)
end
test_a_none_called_file_is_runner()

local function test_one_uncalled_of_two_is_mixed()
  local src = "local function test_a()\n  return 1\nend\ntest_a()\n\n"
  .. "local function test_b()\n  return 2\nend\n"
  local d = walk(src)
  check.equal(d.mode, "mixed")
  check.truthy(d.cases[1].called, "test_a self-calls")
  check.truthy(not d.cases[2].called, "test_b does not")
end
test_one_uncalled_of_two_is_mixed()

local function test_late_calls_do_not_make_a_runner_file()
  -- Both tests are called, at the bottom: under legacy semantics they
  -- run, but discovery must not read the file as runner mode — the
  -- seam's tail would run them a second time.
  local src = "local function test_a()\n  return 1\nend\n"
  .. "local function test_b()\n  return 2\nend\ntest_a()\ntest_b()\n"
  local d = walk(src)
  check.equal(d.mode, "mixed")
end
test_late_calls_do_not_make_a_runner_file()

local function test_an_indirect_reference_disqualifies_runner()
  -- pcall(test_a) is not a call token pair, but the name is referenced:
  -- the file is not runner mode.
  local src = "local function test_a()\n  return 1\nend\npcall(test_a)\n"
  local d = walk(src)
  check.equal(d.mode, "mixed")
end
test_an_indirect_reference_disqualifies_runner()

local function test_helpers_and_quoted_definitions_are_not_cases()
  local src = "local function make_fixture()\n  return 1\nend\n\n"
  .. "local function test_a()\n"
  .. "  local s = \"local function test_quoted() end\"\n"
  .. "  return s\nend\ntest_a()\n"
  local d = walk(src)
  check.equal(d.mode, "legacy")
  check.equal(#d.cases, 1, "the helper and the quoted definition are not cases")
  check.equal(d.cases[1].name, "test_a")
end
test_helpers_and_quoted_definitions_are_not_cases()

local function test_a_file_with_no_tests_is_empty()
  local src = "local function helper()\n  return 1\nend\nreturn helper\n"
  local d = walk(src)
  check.equal(d.mode, "empty")
  check.equal(#d.cases, 0)
end
test_a_file_with_no_tests_is_empty()

local function test_blank_lines_before_the_call_still_count()
  local src = "local function test_a()\n  return 1\nend\n\n\ntest_a()\n"
  local d = walk(src)
  check.equal(d.mode, "legacy")
  check.truthy(d.cases[1].called, "the next NON-BLANK line is the call site")
end
test_blank_lines_before_the_call_still_count()

local function test_nested_blocks_do_not_move_the_end()
  local src = "local function test_a()\n  for i = 1, 2 do\n"
  .. "    if i > 1 then\n      local x = i\n    end\n  end\n"
  .. "  while false do\n    break\n  end\n  return 1\nend\ntest_a()\n"
  local d = walk(src)
  check.equal(d.mode, "legacy")
  check.truthy(d.cases[1].called)
end
test_nested_blocks_do_not_move_the_end()
