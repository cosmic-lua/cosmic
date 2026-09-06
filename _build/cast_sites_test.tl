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

--- Writes a fixture source file and its committed tsv under
--- `TEST_TMPDIR/<name>`, so `reconcile` can be exercised against a
--- tree it does not have to share with the real one.
--- @param name string A subdirectory under `TEST_TMPDIR`, unique per case
--- @param source string The `.tl` file's contents, at its NEW lines
--- @param old_rows {{string, integer, string}} Committed (path, line, class) rows
--- @return string The fixture root
--- @return string The tsv path
local function write_fixture(name: string, source: string,
    old_rows: {{string, integer, string}}): string, string
  local root = fs.join(check.must(os.getenv("TEST_TMPDIR")), name)
  assert(fs.make_dirs(fs.join(root, "cosmic")))
  assert(fs.write(fs.join(root, "cosmic", "shift_test.tl"), source))
  local tsv_lines = {"path\tline\tclass\n"}
  for _, r in ipairs(old_rows) do
    tsv_lines[#tsv_lines + 1] = string.format(
      "%s\t%d\t%s\n", r[1], r[2], r[3])
  end
  local tsv_path = fs.join(root, "cast-sites.tsv")
  assert(fs.write(tsv_path, table.concat(tsv_lines)))
  return root, tsv_path
end

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

-- Both casts shift by the same one line (a comment inserted above
-- them both) and land far enough apart that neither new line collides
-- with the OTHER cast's old line. Exact-key matching finds nothing;
-- the shift pass pairs the two orphans with the two newcomers in line
-- order and carries each class across.
local function test_a_pure_line_shift_carries_both_classes_forward()
  local source = table.concat({
      "-- inserted comment",
      "local a = x as {string} -- cast: reason a",
      "local p = 1",
      "local q = 2",
      "local r = 3",
      "local b = y as {string} -- cast: reason b",
    }, "\n") .. "\n"
  local root, tsv_path = write_fixture("shift-both", source, {
      {"cosmic/shift_test.tl", 1, "classA"},
      {"cosmic/shift_test.tl", 5, "classB"},
    })
  local rows, unclassified = cast_sites.reconcile(root, tsv_path)
  assert(#unclassified == 0,
    "expected no unclassified sites, got: " .. table.concat(unclassified, ", "))
  local got = check.must(rows, "reconcile of a pure shift should succeed")
  assert(#got == 2, "expected 2 rows, got " .. tostring(#got))
  assert(got[1].line == 2 and got[1].class == "classA",
    "first row: line " .. tostring(got[1].line) .. " class " .. got[1].class)
  assert(got[2].line == 6 and got[2].class == "classB",
    "second row: line " .. tostring(got[2].line) .. " class " .. got[2].class)
end

-- The two original casts keep their exact lines; a third cast is
-- appended with nothing to carry from (0 orphans for 1 newcomer), so
-- it stays unclassified and the reconciled file is refused.
local function test_a_new_cast_with_no_orphan_stays_unclassified()
  local source = table.concat({
      "local a = x as {string} -- cast: reason a",
      "local b = y as {string} -- cast: reason b",
      "local c = z as {string} -- cast: reason c",
    }, "\n") .. "\n"
  local root, tsv_path = write_fixture("add-third", source, {
      {"cosmic/shift_test.tl", 1, "classA"},
      {"cosmic/shift_test.tl", 2, "classB"},
    })
  local rows, unclassified = cast_sites.reconcile(root, tsv_path)
  assert(rows == nil, "expected reconcile to refuse, got rows")
  assert(#unclassified == 1,
    "expected 1 unclassified site, got " .. tostring(#unclassified))
  assert(unclassified[1] == "cosmic/shift_test.tl\t3",
    "unexpected unclassified key: " .. unclassified[1])
end

-- One cast is deleted and the survivor shifts far enough that it
-- collides with neither old line: 2 orphans (both original rows) vs.
-- 1 newcomer (the survivor at its new line). The lengths differ, so
-- nothing carries — the survivor stays unclassified and both orphans
-- simply drop, exactly as a real removal should read.
local function test_mismatched_orphan_and_newcomer_counts_carry_nothing()
  local source = table.concat({
      "-- one",
      "-- two",
      "-- three",
      "local a = x as {string} -- cast: reason a",
    }, "\n") .. "\n"
  local root, tsv_path = write_fixture("delete-and-shift", source, {
      {"cosmic/shift_test.tl", 1, "classA"},
      {"cosmic/shift_test.tl", 2, "classB"},
    })
  local rows, unclassified = cast_sites.reconcile(root, tsv_path)
  assert(rows == nil, "expected reconcile to refuse, got rows")
  assert(#unclassified == 1,
    "expected 1 unclassified site, got " .. tostring(#unclassified))
  assert(unclassified[1] == "cosmic/shift_test.tl\t4",
    "unexpected unclassified key: " .. unclassified[1])
end

print("all cast site inventory tests passed")
