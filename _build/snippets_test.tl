#!/usr/bin/env cosmic
--- reads: README.md
--- reads: AGENTS.md
--- reads: docs
--- reads: skills
--- reads: sys
--- reads: cmd
--- reads: cosmic
--- reads: _build
--- reads: _cli
--- reads: _docs
--- reads: _make
--- reads: _perf
--- reads: _tool
--- reads: _types
-- Every code snippet this repository shows a reader is real code.
--
-- "Shows a reader" is the whole surface, not one directory: the pages
-- `--docs <kind>.<topic>` serves, the fenced examples inside module doc
-- comments that `--docs cosmic.shm` prints, the README a visitor lands
-- on, and the markdown under docs/. A snippet is advice, and advice
-- that does not compile is worse than no advice — the reader pastes it,
-- their gate rejects it, and the page was the thing that lied.
--
-- The checks themselves live in `_docs/snippets.tl`, which is also the
-- per-file command a page author runs while writing. This file is the
-- gate: the whole population, from its own `--- reads:` declarations.

local check = require("cosmic.check")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local snippets = require("_docs.snippets")

--- The files this test reads, from its own `--- reads:` declarations
--- above. One list, two consumers: make takes it as the prerequisite
--- set and the content key — so editing a page re-runs this test
--- rather than replaying its verdict — and the scan below takes it as
--- the population. Deriving the second from the first is what keeps
--- them from drifting, and the model refuses a declaration naming a
--- path that does not exist.
local function declared_files(): {string}
  local imports = require("_make.imports")
  return check.must(imports.reads_of_file(".", "_build/snippets_test.tl"))
end

--- Write the example project the docs describe.
local function fixture_dir(): string
  local dir = fs.join(check.must(env.get("TEST_TMPDIR")), "doc-fixtures")
  check.must(snippets.write_fixtures(dir))
  return dir
end

local FENCES < const > = snippets.fences_of(declared_files())

local function test_every_snippet_is_a_formatter_fixpoint()
  local offenders, checked = snippets.formatter_offenders(FENCES)
  assert(checked > 0, "no fence parsed; the harness is broken")
  assert(#offenders == 0,
    "snippet(s) the formatter would rewrite — advice must pass the " ..
    "gate it teaches; a fence ABOUT wrong formatting is prose, so tag " ..
    "it ```text:\n" .. table.concat(offenders, "\n"))
  print("formatter fixpoint: " .. checked .. " snippets")
end

local function test_every_snippet_compiles()
  local offenders, checked = snippets.compile_offenders(FENCES, fixture_dir())
  assert(checked > 0, "no fence was compiled; the harness is broken")
  assert(#offenders == 0,
    "snippet(s) that do not compile as real code — warnings are errors " ..
    "here, exactly as they are for the reader; a fence ABOUT " ..
    "non-compiling code is prose, so tag it ```text:\n" ..
    table.concat(offenders, "\n"))
  print("compiled: " .. checked .. " snippets")
end
