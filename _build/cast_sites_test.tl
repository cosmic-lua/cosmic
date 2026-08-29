#!/usr/bin/env cosmic
--- reads: _build
--- reads: _cli
--- reads: _docs
--- reads: _make
--- reads: _perf
--- reads: _tool
--- reads: _types
--- reads: cmd
--- reads: cosmic
--- reads: docs/design
-- Ratchet over `docs/design/cast-sites.tsv`, the cast site inventory.
--
-- The map drifts the moment a cast closes: the row survives, the site
-- does not. Nothing read the file before this gate, so a closure could
-- lower `_build/casts_baseline.tl` and leave the inventory saying
-- otherwise with `--make ci` still green. Three checks, all against
-- what is actually committed: the per-file count the inventory implies
-- agrees with the cast baseline (which subsumes the total), every
-- class named in the inventory has a heading in `docs/design/casts.md`
-- and every heading has at least one row, and every row's line really
-- holds an `as` cast by the lexer `_cli.lint.cast_lines` uses, not by
-- grepping for the word `as` — the grep also matches the word in prose.

local cast_sites = require("_build.cast_sites")
local casts = require("_build.casts")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local lint = require("_cli.lint")

local CASTS_MD < const > = "docs/design/casts.md"

local REGEN < const > =
"regenerate: bin/cosmic --make run _build/cast_sites.tl --reconcile" ..
" (carries the class forward for a site that still exists; a newly" ..
" discovered site has none and must be classified by hand first)" ..
" and commit the result"

local function test_per_file_counts_agree_with_the_cast_baseline()
  local rows = check.must(cast_sites.read_tsv())
  local per_file: {string: integer} = {}
  for _, r in ipairs(rows) do
    per_file[r.path] = (per_file[r.path] or 0) + 1
  end
  local base = check.must(casts.baseline())
  local mismatched: {string} = {}
  for path, n in pairs(per_file) do
    local want = base[path] or 0
    if n ~= want then
      mismatched[#mismatched + 1] = string.format(
        "%s: %d row(s) in cast-sites.tsv, %d in the cast baseline",
        path, n, want)
    end
  end
  for path, want in pairs(base) do
    if not per_file[path] then
      mismatched[#mismatched + 1] = string.format(
        "%s: 0 row(s) in cast-sites.tsv, %d in the cast baseline",
        path, want)
    end
  end
  table.sort(mismatched)
  assert(#mismatched == 0,
    "docs/design/cast-sites.tsv disagrees with the cast baseline — "
    .. REGEN .. ":\n  " .. table.concat(mismatched, "\n  "))
end
test_per_file_counts_agree_with_the_cast_baseline()

local function test_every_class_has_a_heading_and_every_heading_has_a_row()
  local rows = check.must(cast_sites.read_tsv())
  local class_rows: {string: integer} = {}
  for _, r in ipairs(rows) do
    class_rows[r.class] = (class_rows[r.class] or 0) + 1
  end
  local doc = check.must(fs.read(CASTS_MD))
  local headings: {string: boolean} = {}
  for line in doc:gmatch("[^\n]+") do
    local h = line:match("^### (.+)$")
    if h then
      headings[h] = true
    end
  end
  local missing_heading: {string} = {}
  for class in pairs(class_rows) do
    if not headings[class] then
      missing_heading[#missing_heading + 1] = class
    end
  end
  local missing_row: {string} = {}
  for heading in pairs(headings) do
    if not class_rows[heading] then
      missing_row[#missing_row + 1] = heading
    end
  end
  table.sort(missing_heading)
  table.sort(missing_row)
  assert(#missing_heading == 0,
    "class(es) in cast-sites.tsv with no '### ' heading in "
    .. CASTS_MD .. ":\n  " .. table.concat(missing_heading, "\n  "))
  assert(#missing_row == 0,
    "'### ' heading(s) in " .. CASTS_MD .. " with no row in"
    .. " cast-sites.tsv:\n  " .. table.concat(missing_row, "\n  "))
end
test_every_class_has_a_heading_and_every_heading_has_a_row()

local function test_every_row_holds_a_real_cast()
  local rows = check.must(cast_sites.read_tsv())
  local cast_lines_by_path: {string: {integer: boolean}} = {}
  local bad: {string} = {}
  for _, r in ipairs(rows) do
    local at = cast_lines_by_path[r.path]
    if not at then
      at = {}
      local text = fs.read(r.path)
      if text then
        for _, y in ipairs(lint.cast_lines(text, r.path)) do
          at[y] = true
        end
      end
      cast_lines_by_path[r.path] = at
    end
    if not at[r.line] then
      bad[#bad + 1] = string.format(
        "%s:%d: no `as` token on this line", r.path, r.line)
    end
  end
  table.sort(bad)
  assert(#bad == 0,
    "row(s) in cast-sites.tsv name a line with no real cast — "
    .. REGEN .. ":\n  " .. table.concat(bad, "\n  "))
end
test_every_row_holds_a_real_cast()

print("all cast site inventory tests passed")
