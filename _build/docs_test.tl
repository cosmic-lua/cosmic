#!/usr/bin/env cosmic
--- reads: docs
--- reads: README.md
--- reads: AGENTS.md
--- reads: skills
--- reads: cosmic
--- reads: _tool
-- Ratchets over the DERIVED regions of committed documents.
--
-- A row that restates something the tree already says is a copy, and a
-- copy drifts. The decisions index is every record's own H1, written
-- out a second time -- so the index can disagree with the record it
-- links to. An example fence in a page is the same shape one level
-- down: the body of an `Example_*` function, written out a second time
-- where a reader sees it, so the page can show code and output that
-- the runner no longer produces.
--
-- The regions stay committed because they are read on GitHub, by
-- people who are not running a build. So this is the `.cosmic-coverage`
-- shape: a derived region, a command that rewrites it, and a gate that
-- fails when the committed copy has gone stale.

local check = require("cosmic.check")
local derive = require("_docs.derive")
local examples = require("_docs.examples")
local fs = require("cosmic.fs")

-- The index says exactly what the records say. Compared as a whole
-- table rather than row by row, because the failures worth catching are
-- a row that drifted, a record with no row, and a row whose record is
-- gone -- and only the whole table sees all three.
local function test_the_decisions_index_matches_the_records()
  local rendered, bad = derive.decisions_table()
  assert(#bad == 0,
    "decision record(s) the index cannot be derived from:\n  " ..
    table.concat(bad, "\n  "))

  local text = check.must(fs.read(derive.INDEX))
  local committed = derive.committed_table(text, derive.DECISIONS_HEAD)
  assert(committed ~= "",
    derive.INDEX .. " has no `" .. derive.DECISIONS_HEAD .. "` table")
  assert(committed == rendered,
    derive.INDEX .. " no longer matches the records it indexes.\n" ..
    "Run `bin/cosmic _docs/derive.tl` to rewrite it.\n\ncommitted:\n" ..
    committed .. "\n\nfrom the records:\n" .. rendered)
end

-- Every derived fence carries exactly the body of the function it
-- names. A reference nobody can resolve fails too: a fence left as
-- typed is the hand-written output claim the mechanism replaces.
local function test_every_example_fence_matches_its_source()
  local stale: {string} = {}
  local unresolved: {string} = {}
  local checked = 0
  for _, path in ipairs(examples.documents()) do
    local text = check.must(fs.read(path))
    for _, fence in ipairs(examples.fences(text)) do
      checked = checked + 1
      local where = path .. ":" .. fence.line
      local body, err = examples.body_of(fence.ref)
      if not body then
        unresolved[#unresolved + 1] = where .. ": " .. err
      elseif body ~= fence.body then
        stale[#stale + 1] = where .. ": " .. fence.ref.path .. "#" ..
        fence.ref.name
      end
    end
  end
  assert(#unresolved == 0,
    "example fence(s) naming a function that is not there:\n  " ..
    table.concat(unresolved, "\n  "))
  assert(#stale == 0,
    "example fence(s) that no longer match their source.\n" ..
    "Run `bin/cosmic _docs/derive.tl` to rewrite them:\n  " ..
    table.concat(stale, "\n  "))
  assert(checked > 0, "no derived fence found; the harness is broken")
  print("derived fences: " .. checked)
end

print("all derived-document tests passed")
