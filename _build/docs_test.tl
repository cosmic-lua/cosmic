#!/usr/bin/env cosmic
--- reads: docs/decisions
-- Ratchets over the DERIVED regions of committed documents.
--
-- A row that restates something the tree already says is a copy, and a
-- copy drifts. The decisions index is every record's own H1, written
-- out a second time -- so the index can disagree with the record it
-- links to.
--
-- The rows stay committed because they are read on GitHub, by people
-- who are not running a build. So this is the `.cosmic-coverage` shape:
-- a derived file, a command that rewrites it, and a gate that fails
-- when the committed copy has gone stale.

local check = require("cosmic.check")
local derive = require("_docs.derive")
local fs = require("cosmic.fs")

-- The index says exactly what the records say. Compared as a whole
-- table rather than row by row, because the failures worth catching are
-- a row that drifted, a record with no row, and a row whose record is
-- gone -- and only the whole table sees all three.
local function test_the_decisions_index_matches_the_records()
  local rendered, bad = derive.decisions_table()
  assert(#bad == 0,
    "decision record(s) with no `# D<n> — <title>` heading, so they " ..
    "cannot be indexed:\n  " .. table.concat(bad, "\n  "))

  local text = check.must(fs.read(derive.INDEX))
  local committed = derive.committed_table(text, derive.DECISIONS_HEAD)
  assert(committed ~= "",
    derive.INDEX .. " has no `" .. derive.DECISIONS_HEAD .. "` table")
  assert(committed == rendered,
    derive.INDEX .. " no longer matches the records it indexes.\n" ..
    "Run `bin/cosmic _docs/derive.tl` to rewrite it.\n\ncommitted:\n" ..
    committed .. "\n\nfrom the records:\n" .. rendered)
end
test_the_decisions_index_matches_the_records()

-- The module table says exactly what the doc index says — the same
-- index `--help` renders its module list from, so AGENTS.md cannot
-- describe a module differently than the binary does. A row's
-- text is its module's H1 first line; fix a row at the module header.
local function test_the_module_table_matches_the_doc_index()
  local rendered = derive.modules_table()
  local text = check.must(fs.read(derive.AGENTS))
  local committed = derive.committed_table(text, derive.MODULES_HEAD)
  assert(committed ~= "",
    derive.AGENTS .. " has no `" .. derive.MODULES_HEAD .. "` table")
  assert(committed == rendered,
    derive.AGENTS .. " no longer matches the doc index.\n" ..
    "Run `bin/cosmic _docs/derive.tl` to rewrite it.\n\ncommitted:\n" ..
    committed .. "\n\nfrom the index:\n" .. rendered)
end
test_the_module_table_matches_the_doc_index()

print("all derived-document tests passed")
