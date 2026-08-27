#!/usr/bin/env cosmic
--- reads: _build
--- reads: _cli
--- reads: _docs
--- reads: _eval
--- reads: _fuzz
--- reads: _make
--- reads: _perf
--- reads: _tool
--- reads: _types
--- reads: cmd
--- reads: cosmic
-- Test discovery. One lex-and-parse pass classifies a test file —
-- legacy (every top-level test_* self-called), runner (none called,
-- and no case name referenced anywhere else), mixed (the D29 shape
-- that must never pass), empty (no test_* at all) — and yields the
-- ordered case list.

local check = require("cosmic.check")
local discover = require("_tool.discover")
local fs = require("cosmic.fs")
local tl = require("tl")

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

-- The 3IP9ijhv pair, first shape: a nested type declaration closes
-- with `end` — the old depth count read that `end` as the function's
-- and judged the call misplaced on a correct file.
local function test_a_nested_type_declaration_does_not_move_the_end()
  local src = "local function test_a()\n"
  .. "  local record Case\n    want: string\n  end\n"
  .. "  local c: Case = {want = \"x\"}\n  assert(c.want == \"x\")\n"
  .. "end\ntest_a()\n"
  local d = walk(src)
  check.equal(d.mode, "legacy", "a nested record is not the function's end")
  check.equal(#d.cases, 1)
  check.truthy(d.cases[1].called)

  local enum_src = "local function test_a()\n"
  .. "  local enum Color\n    \"red\"\n  end\n"
  .. "  local c: Color = \"red\"\n  assert(c == \"red\")\n"
  .. "end\ntest_a()\n"
  local e = walk(enum_src)
  check.equal(e.mode, "legacy", "a nested enum is not the function's end")
  check.truthy(e.cases[1].called)

  local iface_src = "local function test_a()\n"
  .. "  local interface Shape\n    kind: string\n  end\n"
  .. "  assert(Shape)\n"
  .. "end\ntest_a()\n"
  local i = walk(iface_src)
  check.equal(i.mode, "legacy", "a nested interface is not the function's end")
  check.truthy(i.cases[1].called)
end
test_a_nested_type_declaration_does_not_move_the_end()

-- The pair's second shape: a `function` token in TYPE position opens
-- no block, so the old count never closed and the definition was
-- silently skipped — under the D29 seam, a test that stops running.
local function test_a_type_position_function_does_not_lose_the_case()
  local src = "local function test_a()\n"
  .. "  local f: function(string): integer\n"
  .. "  assert(f == nil)\n"
  .. "end\ntest_a()\n"
  local d = walk(src)
  check.equal(#d.cases, 1, "an annotation's function type is not an opener")
  check.equal(d.mode, "legacy")
  check.truthy(d.cases[1].called)

  local is_src = "local function test_a()\n"
  .. "  local x: any = 1\n"
  .. "  assert(not (x is function(any): (any, any)))\n"
  .. "end\ntest_a()\n"
  local e = walk(is_src)
  check.equal(#e.cases, 1, "an `is` function type is not an opener")
  check.truthy(e.cases[1].called)
end
test_a_type_position_function_does_not_lose_the_case()

--- The trees of committed Teal source, as `_build/casts.tl` walks
--- them; `3p/` is vendored and `testdata/` holds fixtures with their
--- own roots, so neither counts.
local TREES < const >: {string} = {
  "_build", "_cli", "_docs", "_eval",
  "_fuzz", "_make", "_perf", "_tool",
  "_types", "cmd", "cosmic",
}

--- The independent reference count: the token triple `local` at
--- column 1, `function`, `test_*` name. Token-exact so a definition
--- quoted in a long-bracket fixture never counts — a plain grep reads
--- those, and the tree has five (four in `_tool/seam_test.tl`, one in
--- `_make/resolution_test.tl`).
local function defined_count(src: string, path: string): integer
  local tokens = tl.lex(src, path)
  if not tokens then
    return 0
  end
  local n = 0
  for i = 1, #tokens - 2 do
    if tokens[i].tk == "local" and tokens[i].x == 1
    and tokens[i + 1].tk == "function"
    and tokens[i + 2].tk:match("^test_") then
      n = n + 1
    end
  end
  return n
end

-- The regression net over both shapes at once: every top-level
-- `local function test_*` the tree defines is a case discover yields.
-- Asserted over the whole tree, not a fixture, because the failure
-- mode is silence — a skipped definition reports nothing anywhere
-- else until its file migrates to runner mode and the test stops
-- running.
local function test_discover_finds_every_definition_in_the_tree()
  local shortfall: {string} = {}
  local files = 0
  for _, tree in ipairs(TREES) do
    if fs.is_dir(tree) then
      local found = check.must(fs.find(tree, {glob = "*_test.tl"}))
      for _, path in ipairs(found) do
        if not ("/" .. path):find("/testdata/", 1, true) then
          files = files + 1
          local src = check.must(fs.read(path))
          local defs = defined_count(src, path)
          local d = discover.discover(path, src, lines_of(src))
          if #d.cases ~= defs then
            shortfall[#shortfall + 1] = string.format(
              "%s: %d definitions, discover found %d", path, defs, #d.cases)
          end
        end
      end
    end
  end
  check.truthy(files > 200, "the walk must actually see the tree's tests")
  assert(#shortfall == 0,
    "discover must find every top-level test_* definition:\n  "
    .. table.concat(shortfall, "\n  "))
end
test_discover_finds_every_definition_in_the_tree()
