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
-- A site is keyed by `(path, enclosing function, ordinal)`, never by
-- line, so a line shift never drifts the map from what it names —
-- checked directly below by shifting real casts and reconciling.
-- Four more checks, all against what is actually committed: the
-- per-file count the inventory implies agrees with the cast baseline
-- (which subsumes the total), every class named in the inventory has
-- a heading in `docs/design/casts.md` and every heading has at least
-- one row, every row's cast text still names a real cast site on
-- the current tree, and the header row the doc states is the file's own.

local cast_sites = require("_build.cast_sites")
local casts = require("_build.casts")
local check = require("cosmic.check")
local fs = require("cosmic.fs")

--- Sets up a fixture at `TEST_TMPDIR/<name>`: writes `source` to
--- `cosmic/shift_test.tl` and `rows` to a sibling `cast-sites.tsv`,
--- the same layout `reconcile` reads for real (a tsv beside the tree
--- it describes, never git-tracked).
--- @param name string A subdirectory under `TEST_TMPDIR`, unique per case
--- @param source string The `.tl` file's current contents
--- @param rows {{string, string, integer, string, string}} Committed
--- (path, fn, n, cast, class) rows
--- @return string The fixture root
--- @return string The tsv path
local function write_fixture(name: string, source: string,
    rows: {{string, string, integer, string, string}}): string, string
  local root = fs.join(check.must(os.getenv("TEST_TMPDIR")), name)
  assert(fs.make_dirs(fs.join(root, "cosmic")))
  assert(fs.write(fs.join(root, "cosmic", "shift_test.tl"), source))
  local tsv_lines = {"path\tfn\tn\tcast\tclass\n"}
  for _, r in ipairs(rows) do
    tsv_lines[#tsv_lines + 1] = string.format(
      "%s\t%s\t%d\t%s\t%s\n", r[1], r[2], r[3], r[4], r[5])
  end
  local tsv_path = fs.join(root, "cast-sites.tsv")
  assert(fs.write(tsv_path, table.concat(tsv_lines)))
  return root, tsv_path
end

local CASTS_MD < const > = "docs/design/casts.md"

local REGEN < const > =
"regenerate: bin/cosmic --make run _build/cast_sites.tl --reconcile" ..
" (carries the class forward for a site whose key still matches; a" ..
" newly discovered key has none and must be classified by hand first)" ..
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

local function test_every_row_names_a_real_site()
  local rows = check.must(cast_sites.read_tsv())
  local real: {string: boolean} = {}
  for _, s in ipairs(cast_sites.scan(".")) do
    real[s.path .. "\t" .. s.fn .. "\t" .. s.n] = true
  end
  local bad: {string} = {}
  for _, r in ipairs(rows) do
    if not real[r.path .. "\t" .. r.fn .. "\t" .. r.n] then
      bad[#bad + 1] = string.format("%s: %s#%d is not a real cast site", r.path, r.fn, r.n)
    end
  end
  table.sort(bad)
  assert(#bad == 0,
    "row(s) in cast-sites.tsv name a site the tree no longer has — "
    .. REGEN .. ":\n  " .. table.concat(bad, "\n  "))
end

-- Two casts share one function; a line inserted above both shifts them
-- down by one without touching their relative order. Neither cast's
-- key (function, ordinal) depends on a line number at all, so
-- reconcile finds the exact same two keys it was given classes for —
-- no reconcile forced, no finding raised.
local function test_a_line_shift_leaves_both_keys_unchanged()
  local source = table.concat({
      "-- inserted comment, shifting every line below by one",
      "local function shifted(x: any): integer",
      "  local a = x as integer -- cast: reason a",
      "  local b = x as string -- cast: reason b",
      "  return a",
      "end",
    }, "\n") .. "\n"
  local root, tsv_path = write_fixture("line-shift", source, {
      {"cosmic/shift_test.tl", "shifted", 1, "local a = x as integer -- cast: reason a", "classA"},
      {"cosmic/shift_test.tl", "shifted", 2, "local b = x as string -- cast: reason b", "classB"},
    })
  local rows, findings = cast_sites.reconcile(root, tsv_path)
  assert(#findings == 0,
    "expected no findings, got: " .. table.concat(findings, ", "))
  local got = check.must(rows, "reconcile of a pure shift should succeed")
  assert(#got == 2, "expected 2 rows, got " .. tostring(#got))
  assert(got[1].fn == "shifted" and got[1].n == 1 and got[1].class == "classA",
    "first row: fn " .. got[1].fn .. " n " .. tostring(got[1].n) .. " class " .. got[1].class)
  assert(got[2].fn == "shifted" and got[2].n == 2 and got[2].class == "classB",
    "second row: fn " .. got[2].fn .. " n " .. tostring(got[2].n) .. " class " .. got[2].class)
end

-- The cast's own text is untouched but it now sits inside a different
-- function, so its key changes even though nothing shifted a line.
-- `(path, fn, n)` no longer matches any committed row, so reconcile
-- refuses — but because the cast's exact text still matches exactly
-- one orphaned row, the refusal's one finding names both the new key
-- and the old one, so a person can carry the class across by hand.
local function test_a_cast_moved_to_another_function_gets_a_finding_naming_both_keys()
  local source = table.concat({
      "local function origin(): integer",
      "  return 0",
      "end",
      "",
      "local function destination(x: any): integer",
      "  local a = x as integer -- cast: reason a",
      "  return a",
      "end",
    }, "\n") .. "\n"
  local root, tsv_path = write_fixture("moved-function", source, {
      {"cosmic/shift_test.tl", "origin", 1, "local a = x as integer -- cast: reason a", "classA"},
    })
  local rows, findings = cast_sites.reconcile(root, tsv_path)
  assert(rows == nil, "expected reconcile to refuse, got rows")
  assert(#findings == 1, "expected 1 finding, got " .. tostring(#findings))
  local finding = findings[1]
  assert(finding:find("cosmic/shift_test.tl\tdestination\t1", 1, true),
    "finding names the new key: " .. finding)
  assert(finding:find("cosmic/shift_test.tl\torigin\t1", 1, true),
    "finding names the old key: " .. finding)
  assert(finding:find("classA", 1, true),
    "finding names the class carried from: " .. finding)
end

-- A cast's own text is edited in place (its ordinal and enclosing
-- function unchanged) — reconcile matches on `(path, fn, n)` alone, so
-- the class still carries, and the committed row's `cast` column now
-- shows the new text, which is what makes the edit visible on review.
local function test_an_edited_cast_text_keeps_its_class_at_the_same_key()
  local source = table.concat({
      "local function edited(x: any): integer",
      "  local a = x as string -- cast: reason a, edited",
      "  return 0",
      "end",
    }, "\n") .. "\n"
  local root, tsv_path = write_fixture("edited-text", source, {
      {"cosmic/shift_test.tl", "edited", 1, "local a = x as integer -- cast: reason a", "classA"},
    })
  local rows, findings = cast_sites.reconcile(root, tsv_path)
  assert(#findings == 0, "expected no findings, got: " .. table.concat(findings, ", "))
  local got = check.must(rows, "reconcile of an in-place edit should succeed")
  assert(#got == 1, "expected 1 row, got " .. tostring(#got))
  assert(got[1].class == "classA", "class should still carry, got " .. got[1].class)
  assert(got[1].cast == "local a = x as string -- cast: reason a, edited",
    "committed cast text should reflect the edit, got: " .. got[1].cast)
end

-- A cast with no matching key and no orphan sharing its exact text
-- (a genuinely new site) is refused with just its own key — nothing to
-- pair it with.
local function test_a_brand_new_site_is_refused_with_just_its_own_key()
  local source = table.concat({
      "local function fresh(x: any): integer",
      "  local a = x as integer -- cast: reason a",
      "  return a",
      "end",
    }, "\n") .. "\n"
  local root, tsv_path = write_fixture("brand-new", source, {})
  local rows, findings = cast_sites.reconcile(root, tsv_path)
  assert(rows == nil, "expected reconcile to refuse, got rows")
  assert(#findings == 1, "expected 1 finding, got " .. tostring(#findings))
  assert(findings[1] == "cosmic/shift_test.tl\tfresh\t1",
    "unexpected finding: " .. findings[1])
end

local function test_the_doc_states_the_tsv_header_row_exactly()
  local tsv = check.must(fs.read("docs/design/cast-sites.tsv"))
  local header = tsv:match("^([^\n]*)\n")
  local doc = check.must(fs.read(CASTS_MD))
  local stated: string = nil
  for line in doc:gmatch("[^\n]*") do
    if line:match("^path\t") then
      stated = line
      break
    end
  end
  assert(stated ~= nil, CASTS_MD .. " states no fenced `path\\t...` header row")
  assert(stated == header, string.format(
      "%s states the header row as %q but cast-sites.tsv opens with %q",
      CASTS_MD, stated, header))
end

print("all cast site inventory tests passed")
