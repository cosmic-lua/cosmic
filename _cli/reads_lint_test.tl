#!/usr/bin/env cosmic
-- The reads-declaration rule: a *_test.tl file that enumerates files
-- with fs.glob() must declare what it read, or its cached PASS can
-- silently outlive the tree it was supposed to re-check (#1227).

local check = require("cosmic.check")
local reads_lint = require("_cli.reads_lint")
local style = require("_tool.lint")

local type Diagnostic = style.Diagnostic

--- Run the rule over a source string, as lint_file does: split into
--- lines the same way before handing them to the checker.
local function diagnose(file: string, source: string): {Diagnostic}
  local lines: {string} = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return reads_lint.check_reads_declaration(file, source, lines)
end

local GLOB_SRC < const > =
"local fs = require(\"cosmic.fs\")\n" ..
"local found = fs.glob(\"cosmic\", \"*.tl\")\n"

local function test_undeclared_glob_is_flagged()
  local diags = diagnose("cosmic/some_test.tl", GLOB_SRC)
  check.equal(#diags, 1, "an undeclared fs.glob() call must be flagged")
  check.equal(diags[1].rule, "reads-declaration")
  check.equal(diags[1].line, 2)
end

local function test_declared_glob_passes()
  local src = "--- reads: some/dir\n" .. GLOB_SRC
  check.equal(#diagnose("cosmic/some_test.tl", src), 0,
    "a `--- reads:` header must clear the finding")
end

local function test_allowlisted_file_passes()
  check.equal(#diagnose("cosmic/fs/glob_test.tl", GLOB_SRC), 0,
    "the allowlisted glob_test.tl must pass with no header")
end

local function test_non_test_file_is_ignored()
  check.equal(#diagnose("cosmic/fs/find.tl", GLOB_SRC), 0,
    "the rule only applies to *_test.tl files")
end

local function test_fs_find_is_not_this_rules_trigger()
  local src = "local fs = require(\"cosmic.fs\")\n" ..
  "local found = fs.find(\"cosmic\", {glob = \"*.tl\"})\n"
  check.equal(#diagnose("cosmic/some_test.tl", src), 0,
    "this slice's trigger is fs.glob only, not fs.find")
end

local function test_reads_build_output_dir_is_flagged()
  local src = "--- reads: o/cmd/cosmic/embed_gen/embed/.docs/index.lua\n"
  .. GLOB_SRC
  local diags = diagnose("_build/some_test.tl", src)
  local found = false
  for _, d in ipairs(diags) do
    if d.rule == "reads-declaration" and d.line == 1
    and d.message:find("names a build output", 1, true) then
      found = true
    end
  end
  check.truthy(found,
    "a `reads: o/...` entry must be flagged as a build output")
end

local function test_reads_bare_o_is_flagged()
  local src = "--- reads: o\n" .. GLOB_SRC
  local diags = diagnose("_build/some_test.tl", src)
  check.equal(#diags, 1, "a bare `reads: o` entry must be flagged")
  check.equal(diags[1].rule, "reads-declaration")
  check.equal(diags[1].line, 1)
end

local function test_reads_path_containing_o_segment_passes()
  local src = "--- reads: docs/o/notes.md\n" .. GLOB_SRC
  local diags = diagnose("_build/some_test.tl", src)
  check.equal(#diags, 0,
    "a path merely containing an `/o/` segment names no build output")
end
