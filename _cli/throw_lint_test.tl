#!/usr/bin/env cosmic
-- The throw and exit rules. D30 licenses a library `error(` or
-- `os.exit(`/`unix.exit(` only where no caller could receive the
-- value, and demands the argument written beside the site as a
-- `-- throws:`/`-- exits:` comment; `throw-justify` and `exit-justify`
-- flag the sites that do not carry it.

local check = require("cosmic.check")
local style = require("_tool.lint")
local throw_lint = require("_cli.throw_lint")

local type Diagnostic = style.Diagnostic

--- Run the rule over a source string at a chosen path, splitting the
--- way lint_file splits.
local function diagnose(source: string, path?: string): {Diagnostic}
  local at = path or "cosmic/fixture.tl"
  local lines: {string} = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return throw_lint.check_throw_justification(at, source, lines)
end

local function test_a_bare_error_is_flagged()
  local diags = diagnose("local function f()\n  error(\"boom\")\nend\n")
  check.equal(#diags, 1, "an unjustified library error must be flagged")
  check.equal(diags[1].rule, "throw-justify")
  check.equal(diags[1].line, 2)
  check.truthy(diags[1].message:find("D30", 1, true),
    "the message names the licence")
  check.truthy(diags[1].message:find("-- throws:", 1, true),
    "the message names the marker to write")
end
test_a_bare_error_is_flagged()

local function test_a_trailing_throws_marker_passes()
  local src = "local function f()\n"
  .. "  error(\"boom\") -- throws: loader protocol; require re-raises\n"
  .. "end\n"
  check.equal(#diagnose(src), 0, "a trailing -- throws: reason licenses")
end
test_a_trailing_throws_marker_passes()

local function test_a_line_above_throws_marker_passes()
  local src = "local function f()\n"
  .. "  -- throws: loader protocol; require re-raises\n"
  .. "  error(\"a very long message that would not fit\")\n"
  .. "end\n"
  check.equal(#diagnose(src), 0, "a line-above -- throws: reason licenses")
end
test_a_line_above_throws_marker_passes()

local function test_a_bare_marker_with_no_reason_fails()
  local src = "local function f()\n  error(\"boom\") -- throws:\nend\n"
  check.equal(#diagnose(src), 1, "a marker with no reason justifies nothing")
end
test_a_bare_marker_with_no_reason_fails()

local function test_a_mismatched_marker_fails()
  -- `-- exits:` on an error line is the wrong grammar: the marker word
  -- states what the site does, and this site throws.
  local src = "local function f()\n"
  .. "  error(\"boom\") -- exits: wrong word for a throw\n"
  .. "end\n"
  local diags = diagnose(src)
  check.equal(#diags, 1, "an -- exits: marker does not license an error(")
  check.equal(diags[1].rule, "throw-justify")
end
test_a_mismatched_marker_fails()

local function test_os_exit_is_flagged_without_exits()
  local diags = diagnose("local function f()\n  os.exit(1)\nend\n")
  check.equal(#diags, 1, "an unjustified os.exit must be flagged")
  check.equal(diags[1].rule, "exit-justify")
  check.truthy(diags[1].message:find("-- exits:", 1, true),
    "the message names the marker to write")
end
test_os_exit_is_flagged_without_exits()

local function test_unix_exit_is_flagged_without_exits()
  -- The quicksand post-fork children exit through the binding, not the
  -- stdlib; the rule covers both receivers.
  local diags = diagnose("local function f()\n  unix.exit(0)\nend\n")
  check.equal(#diags, 1, "an unjustified unix.exit must be flagged")
  check.equal(diags[1].rule, "exit-justify")
end
test_unix_exit_is_flagged_without_exits()

local function test_a_justified_exit_passes()
  local src = "local function f()\n"
  .. "  os.exit(127) -- exits: forked child; the error is on the pipe\n"
  .. "end\n"
  check.equal(#diagnose(src), 0, "a trailing -- exits: reason licenses")
end
test_a_justified_exit_passes()

local function test_other_receivers_and_methods_do_not_count()
  -- `e.error(` is a method on some record, `proc.exit(` is not a
  -- process exit, and a string containing `error(` is data.
  local src = "local function f()\n"
  .. "  e.error(\"x\")\n"
  .. "  proc.exit(1)\n"
  .. "  local s = \"error(boom)\"\n"
  .. "  return s\n"
  .. "end\n"
  check.equal(#diagnose(src), 0, "only bare error and os/unix exit count")
end
test_other_receivers_and_methods_do_not_count()

local function test_tests_and_toolchain_are_out_of_scope()
  local src = "local function f()\n  error(\"boom\")\nend\n"
  check.equal(#diagnose(src, "cosmic/fixture_test.tl"), 0,
    "test files throw freely")
  check.equal(#diagnose(src, "_cli/fixture.tl"), 0,
    "toolchain trees are not governed by D30")
end
test_tests_and_toolchain_are_out_of_scope()

local function test_check_and_rand_are_exempt_at_module_level()
  -- D30 records the two module-wide licences: check's assertions and
  -- exits ARE its contract (D23), rand's CSPRNG throws on failure (D22).
  local src = "local function f()\n  error(\"boom\")\n  os.exit(3)\nend\n"
  check.equal(#diagnose(src, "cosmic/check.tl"), 0, "check.tl is exempt")
  check.equal(#diagnose(src, "cosmic/rand.tl"), 0, "rand.tl is exempt")
end
test_check_and_rand_are_exempt_at_module_level()

local function test_one_diagnostic_per_line()
  local src = "local function f()\n"
  .. "  if x then error(\"a\") else error(\"b\") end\n"
  .. "end\n"
  check.equal(#diagnose(src), 1,
    "a line takes one comment, so it gets one diagnostic")
end
test_one_diagnostic_per_line()

local function test_error_inside_a_long_bracket_is_not_code()
  -- cosmic/embed/init.tl's shape: entry-wrapper SOURCE this tree
  -- writes rather than runs.
  local src = "local WRAP = [[\nerror(\"corrupt artifact\")\nos.exit(1)\n]]\n"
  check.equal(#diagnose(src), 0, "a long-bracket payload is not code")
end
test_error_inside_a_long_bracket_is_not_code()
