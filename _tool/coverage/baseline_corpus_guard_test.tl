#!/usr/bin/env cosmic
--- Tests for `corpus_guard`'s drop-only counting, split out of
--- `baseline_test.tl` (which sits at the 500-line file cap) rather than
--- grown past it.
local baseline = require("_tool.coverage.baseline")
local check = require("cosmic.check")
local rep = require("_tool.coverage.report")

local type FileReport = rep.FileReport

local function reports(rows: {{string, integer, integer}}): {FileReport}
  local out: {FileReport} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = {
      display = row[1],
      covered = row[2],
      total = row[3],
      missing = {},
    }
  end
  return out
end

--- A baseline text literal from `{path, covered, total}` rows.
--- @param rows {{string, integer, integer}} path, covered, total triples
--- @return string A `return { ["path"] = {covered = C, total = T}, ... }` literal
local function fixture(rows: {{string, integer, integer}}): string
  local parts: {string} = {}
  for _, row in ipairs(rows) do
    parts[#parts + 1] = string.format("  [%s] = {covered = %d, total = %d},",
      string.format("%q", row[1]), row[2], row[3])
  end
  return "return {\n" .. table.concat(parts, "\n") .. "\n}\n"
end

-- `moved` finds both directions now, so `corpus_guard` must count only
-- real drops, not everything `moved` returns: a corpus where 2 of 4
-- rows RAISE and only 1 drops must not refuse, even though `moved`
-- reports 3 rows moved. Flip to 3 drops and 1 raise (still 4 moved) and
-- it refuses -- with a count that names the 3 drops, not the raise
-- riding along. This mix is what neither the drop-only nor raise-only
-- fixtures in `baseline_test.tl` exercise.
local function test_corpus_guard_counts_only_real_drops_among_mixed_moves()
  local before = fixture({
      {"a.tl", 1, 10}, {"b.tl", 1, 10}, {"c.tl", 9, 10}, {"d.tl", 9, 10},
    })
  local minority = check.must(baseline.render(reports({ -- a, b raise; c drops; d flat
          {"a.tl", 9, 10}, {"b.tl", 9, 10}, {"c.tl", 1, 10}, {"d.tl", 9, 10},
        })))
  local ok, refusal = baseline.corpus_guard(before, minority)
  assert(ok, "1 real drop among 2 raises must not refuse, got: " .. refusal)
  local min_moves = baseline.moved(before, minority)
  assert(#min_moves == 3,
    "moved still finds all 3 rows that moved, raise and drop alike")
  local min_raised = 0
  for _, m in ipairs(min_moves) do
    if m.raised then min_raised = min_raised + 1 end
  end
  assert(min_raised == 2, "a and b must both be labeled raised, got " .. min_raised)

  local majority = check.must(baseline.render(reports({ -- a raises; b, c, d drop
          {"a.tl", 9, 10}, {"b.tl", 0, 10}, {"c.tl", 1, 10}, {"d.tl", 1, 10},
        })))
  local ok2, refusal2 = baseline.corpus_guard(before, majority)
  assert(not ok2, "3 genuine drops of 4 rows must refuse")
  assert(refusal2:find("lower 3 of 4 floor rows", 1, true),
    "the refusal must count only the 3 real drops, not the raise too, got: " ..
    refusal2)
  assert(#baseline.moved(before, majority) == 4,
    "moved still finds all 4 rows, including the one raise")
end

print("all baseline corpus-guard tests passed")
