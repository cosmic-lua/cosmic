#!/usr/bin/env cosmic
-- The doc-citation rule: a `file:line` citation in a markdown document
-- must name a file that exists, at a line that exists, quoting what is
-- really there -- unless the document declares itself a snapshot of a
-- past commit, whose positions this check cannot read.

local check = require("cosmic.check")
local citations = require("_cli.citations")
local fs = require("cosmic.fs")
local style = require("_tool.lint")

local type Diagnostic = style.Diagnostic

--- Run the rule over a document string, as lint_file does: split into
--- lines the same way before handing them to the checker.
--- @param file string The document's path, for the diagnostics
--- @param source string The document's bytes
--- @return {Diagnostic}
local function diagnose(file: string, source: string): {Diagnostic}
  local lines: {string} = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return citations.check_citations(file, lines)
end

-- Cited paths resolve relative to the process's cwd, which is the
-- project root when `--check lint` runs. So the fixture needs to BE the
-- cwd for the duration of this file, and the old one is restored at the
-- bottom (cosmic/fs/init_test.tl's test_getcwd_and_chdir is the same
-- move on a smaller scale).
local ORIGINAL < const > = check.must(fs.cwd())
local BASE < const > = os.getenv("TEST_TMPDIR")
or check.must(fs.temp_dir("citations"))
local ROOT < const > = fs.join(BASE, "citations-fixture")

assert(fs.make_dirs(fs.join(ROOT, "src")), "fixture src dir")
-- Three lines, of which the second is the one every quote test cites.
assert(fs.write(fs.join(ROOT, "src", "sample.tl"),
    "line one\n  local s = \"two\"\nline three\n"), "fixture source")
assert(fs.set_cwd(ROOT), "chdir into the fixture")

local function test_inline_citation_that_resolves()
  local diags = diagnose("doc.md", "See `src/sample.tl:2` for the shape.")
  check.equal(#diags, 0, "a citation naming a real line must not be flagged")
end
test_inline_citation_that_resolves()

local function test_inline_citation_past_end_of_file()
  local diags = diagnose("doc.md", "See `src/sample.tl:9` for the shape.")
  check.equal(#diags, 1, "a citation past end-of-file must be flagged")
  check.equal(diags[1].rule, "doc-citation")
  check.equal(diags[1].line, 1)
  check.truthy(diags[1].message:find("past end of file", 1, true),
    "the message must say what is wrong: " .. diags[1].message)
end
test_inline_citation_past_end_of_file()

local function test_inline_citation_naming_no_file()
  local diags = diagnose("doc.md", "See `src/renamed.tl:1` for the shape.")
  check.equal(#diags, 1, "a citation naming no file must be flagged")
  check.truthy(diags[1].message:find("names no file", 1, true),
    "the message must name the failure: " .. diags[1].message)
end
test_inline_citation_naming_no_file()

local function test_generated_citation_is_skipped()
  local diags = diagnose("doc.md",
    "The declaration is `o/_types/types_gen/cosmo/path.d.tl:40`.")
  check.equal(#diags, 0,
    "a citation into the build output is generated and unresolvable by"
    .. " design, so it is skipped")
end
test_generated_citation_is_skipped()

local function test_range_inside_the_file()
  local diags = diagnose("doc.md", "The block is `src/sample.tl:1-3`.")
  check.equal(#diags, 0, "a range wholly inside the file must not be flagged")
end
test_range_inside_the_file()

local function test_range_past_end_of_file()
  local diags = diagnose("doc.md", "The block is `src/sample.tl:2-9`.")
  check.equal(#diags, 1, "a range running past end-of-file must be flagged")
end
test_range_past_end_of_file()

--- A fenced block citing the fixture's second line, quoting `quote`.
--- @param quote string The line the document claims is there
--- @return string The document's bytes
local function fenced(quote: string): string
  return "Prose above.\n\n```text\n-- src/sample.tl:2\n" .. quote
  .. "\n```\n\nProse below.\n"
end

local function test_fenced_quote_that_matches()
  local diags = diagnose("doc.md", fenced("  local s = \"two\""))
  check.equal(#diags, 0, "a quote matching its source must not be flagged")
end
test_fenced_quote_that_matches()

local function test_fenced_quote_that_matches_ignoring_indent()
  local diags = diagnose("doc.md", fenced("local s = \"two\""))
  check.equal(#diags, 0,
    "leading and trailing whitespace is stripped from both sides")
end
test_fenced_quote_that_matches_ignoring_indent()

local function test_fenced_quote_that_does_not_match()
  local diags = diagnose("doc.md", fenced("local s = \"three\""))
  check.equal(#diags, 1, "a quote that has drifted must be flagged")
  check.equal(diags[1].rule, "doc-citation")
  check.equal(diags[1].line, 5)
  check.truthy(diags[1].message:find("local s = \"three\"", 1, true),
    "the message must carry what the document says: " .. diags[1].message)
  check.truthy(diags[1].message:find("local s = \"two\"", 1, true),
    "the message must carry what the source says: " .. diags[1].message)
end
test_fenced_quote_that_does_not_match()

--- The same document, prefixed with the sentence that declares a
--- snapshot of a past commit.
--- @param body string The document's remaining bytes
--- @return string The document's bytes
local function snapshot(body: string): string
  return "# doc\n\nMeasured against `deadbee` on 2026-08-26.\n\n" .. body
end

local function test_snapshot_leaves_positions_unjudged()
  local diags = diagnose("doc.md", snapshot(
      fenced("local s = \"three\"") .. "\nAlso `src/sample.tl:9`.\n"))
  check.equal(#diags, 0,
    "a snapshot's line numbers and quotes describe a commit this check"
    .. " cannot read, so neither is judged")
end
test_snapshot_leaves_positions_unjudged()

local function test_snapshot_still_checks_paths()
  local diags = diagnose("doc.md",
    snapshot("The site is `src/renamed.tl:2`.\n"))
  check.equal(#diags, 1,
    "a path renamed away leaves the reader nothing to follow, whichever"
    .. " commit it was measured at")
  check.truthy(diags[1].message:find("names no file", 1, true),
    "the message must name the failure: " .. diags[1].message)
end
test_snapshot_still_checks_paths()

local function test_measured_against_inside_a_fence_is_not_a_declaration()
  local quoted = "```text\nMeasured against `deadbee` on 2026-08-26.\n```\n\n"
  local diags = diagnose("doc.md", quoted .. fenced("local s = \"three\""))
  check.equal(#diags, 1,
    "a document QUOTING the sentence has not declared itself a snapshot")
end
test_measured_against_inside_a_fence_is_not_a_declaration()

local function test_prose_span_that_merely_contains_a_path()
  local diags = diagnose("doc.md", "Run `sed -n 9p src/sample.tl:9` here.")
  check.equal(#diags, 0,
    "only a whole backticked span that is nothing but a citation counts;"
    .. " a command that mentions a path is prose")
end
test_prose_span_that_merely_contains_a_path()

local function test_a_document_with_no_citations()
  local diags = diagnose("doc.md", "# title\n\nProse with `code` in it.\n")
  check.equal(#diags, 0, "a document citing nothing must be clean")
end
test_a_document_with_no_citations()

assert(fs.set_cwd(ORIGINAL), "restore the original cwd")
