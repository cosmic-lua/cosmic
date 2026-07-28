#!/usr/bin/env cosmic
-- Ratchets over the DERIVED regions of committed documents.
--
-- A row that restates something the tree already says is a copy, and a
-- copy drifts. The decisions index is every record's own H1, written
-- out a second time -- so the index can disagree with the record it
-- links to, which is what #820 is about.
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

print("all derived-document tests passed")
