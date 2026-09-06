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
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local lint = require("_cli.lint")

--- Runs a git command inside `root`, failing the test loudly if it
--- does not exit 0 — the fixtures below need `git`'s own history, not
--- a mock of it, since `reconcile`'s shift pass reads `git show HEAD:`.
--- @param root string Working directory for the command
--- @param ...string Arguments after `git`
local function git(root: string, ...: string)
  local argv: {string} = {"git", ...}
  local r = check.must(child.run(argv, {cwd = root}))
  assert(r.ok, "git " .. table.concat({...}, " ") .. " failed:\n"
    .. r.stdout .. r.stderr)
end

--- Sets up a fixture at `TEST_TMPDIR/<name>`: writes `old_source` to
--- `cosmic/shift_test.tl` and, when `track_git`, commits it (so `git
--- show HEAD:` can read it back); then overwrites the source with
--- `new_source`, so the working tree and HEAD disagree exactly the
--- way an edit would. The tsv is never git-tracked — `reconcile` reads
--- it straight off disk, same as the real one.
--- @param name string A subdirectory under `TEST_TMPDIR`, unique per case
--- @param old_source string The `.tl` file's contents AS COMMITTED
--- @param new_source string The `.tl` file's contents in the working tree
--- @param old_rows {{string, integer, string}} Committed (path, line, class) rows
--- @param track_git boolean Whether to `git init` and commit at all
--- @return string The fixture root
--- @return string The tsv path
local function write_fixture(name: string, old_source: string,
    new_source: string, old_rows: {{string, integer, string}},
    track_git: boolean): string, string
  local root = fs.join(check.must(os.getenv("TEST_TMPDIR")), name)
  assert(fs.make_dirs(fs.join(root, "cosmic")))
  local source_path = fs.join(root, "cosmic", "shift_test.tl")
  assert(fs.write(source_path, old_source))
  if track_git then
    git(root, "init", "-q")
    git(root, "add", "cosmic/shift_test.tl")
    git(root, "-c", "user.email=test@example.com", "-c", "user.name=test",
      "commit", "-q", "-m", "initial")
  end
  assert(fs.write(source_path, new_source))
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

-- A comment line inserted above both casts shifts them by the same
-- one line, with their text untouched. Neither survives the exact-key
-- pass; the text pass reads each orphan's line back from `git show
-- HEAD:`, finds each newcomer's current line byte-identical to
-- exactly one of them, and carries both classes across.
local function test_a_pure_line_shift_carries_both_classes_forward()
  local old_source = table.concat({
      "local a = x as {string} -- cast: reason a",
      "local p = 1",
      "local q = 2",
      "local r = 3",
      "local b = y as {string} -- cast: reason b",
    }, "\n") .. "\n"
  local new_source = "-- inserted comment\n" .. old_source
  local root, tsv_path = write_fixture("shift-both", old_source, new_source, {
      {"cosmic/shift_test.tl", 1, "classA"},
      {"cosmic/shift_test.tl", 5, "classB"},
    }, true)
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

-- The two casts trade relative order AND land on lines that match
-- neither original committed line — so the exact-key pass matches
-- neither and both reach the text pass — where position-based pairing
-- would swap their classes, silently. Each cast's line text is
-- distinct and unedited, so the text pass follows the text, not the
-- slot: each newcomer inherits the class of the orphan whose
-- committed text it matches, whichever line that orphan used to sit
-- on, and whichever line the newcomer now sits on.
local function test_a_reorder_follows_text_not_position()
  local old_source = table.concat({
      "local a = x as {string} -- cast: reason a",
      "local p = 1",
      "local q = 2",
      "local r = 3",
      "local b = y as {string} -- cast: reason b",
    }, "\n") .. "\n"
  local new_source = table.concat({
      "-- pad",
      "local b = y as {string} -- cast: reason b",
      "local p = 1",
      "local q = 2",
      "local r = 3",
      "local a = x as {string} -- cast: reason a",
    }, "\n") .. "\n"
  local root, tsv_path = write_fixture("reorder", old_source, new_source, {
      {"cosmic/shift_test.tl", 1, "classA"},
      {"cosmic/shift_test.tl", 5, "classB"},
    }, true)
  local rows, unclassified = cast_sites.reconcile(root, tsv_path)
  assert(#unclassified == 0,
    "expected no unclassified sites, got: " .. table.concat(unclassified, ", "))
  local got = check.must(rows, "reconcile of a reorder should succeed")
  assert(#got == 2, "expected 2 rows, got " .. tostring(#got))
  assert(got[1].line == 2 and got[1].class == "classB",
    "line 2 now holds cast b's text, so it must take classB, got "
    .. got[1].class)
  assert(got[2].line == 6 and got[2].class == "classA",
    "line 6 now holds cast a's text, so it must take classA, got "
    .. got[2].class)
end

-- Two committed casts share byte-identical line text; both shift by
-- the same inserted line. Each newcomer's text matches BOTH orphans,
-- not exactly one, so neither has an honest single class to take —
-- a wrong guess is worse than none, so both stay unclassified.
local function test_identical_text_orphans_stay_ambiguous()
  local old_source = table.concat({
      "local v = x as {string} -- cast: reason",
      "local p = 1",
      "local v = x as {string} -- cast: reason",
    }, "\n") .. "\n"
  local new_source = "-- inserted\n" .. old_source
  local root, tsv_path = write_fixture("identical-text", old_source,
    new_source, {
      {"cosmic/shift_test.tl", 1, "classA"},
      {"cosmic/shift_test.tl", 3, "classB"},
    }, true)
  local rows, unclassified = cast_sites.reconcile(root, tsv_path)
  assert(rows == nil, "expected reconcile to refuse, got rows")
  assert(#unclassified == 2,
    "expected 2 unclassified sites, got " .. tostring(#unclassified))
  assert(unclassified[1] == "cosmic/shift_test.tl\t2"
    and unclassified[2] == "cosmic/shift_test.tl\t4",
    "unexpected unclassified keys: " .. table.concat(unclassified, ", "))
end

-- The cast's line text is edited (not just moved) at the same time it
-- shifts. Its committed text no longer appears among the newcomers'
-- current text at all, so nothing matches — this is a real content
-- change, and it is refused exactly like a brand-new site: the old
-- row drops, the new one asks for a class by hand.
local function test_an_edited_cast_line_asks_for_its_class_again()
  local old_source = table.concat({
      "local a = x as {string} -- cast: reason a",
      "local p = 1",
    }, "\n") .. "\n"
  local new_source = table.concat({
      "-- inserted",
      "local a = x as {integer} -- cast: reason a, edited",
      "local p = 1",
    }, "\n") .. "\n"
  local root, tsv_path = write_fixture("edited-and-shifted", old_source,
    new_source, {
      {"cosmic/shift_test.tl", 1, "classA"},
    }, true)
  local rows, unclassified = cast_sites.reconcile(root, tsv_path)
  assert(rows == nil, "expected reconcile to refuse, got rows")
  assert(#unclassified == 1,
    "expected 1 unclassified site, got " .. tostring(#unclassified))
  assert(unclassified[1] == "cosmic/shift_test.tl\t2",
    "unexpected unclassified key: " .. unclassified[1])
end

-- The fixture root is never `git init`-ed at all, so `git show HEAD:`
-- cannot read the committed text back — there is no committed text to
-- compare against, so both shifted newcomers stay unclassified rather
-- than guessing from position.
local function test_an_untracked_file_carries_nothing()
  local old_source = table.concat({
      "local a = x as {string} -- cast: reason a",
      "local p = 1",
      "local q = 2",
      "local r = 3",
      "local b = y as {string} -- cast: reason b",
    }, "\n") .. "\n"
  local new_source = "-- inserted comment\n" .. old_source
  local root, tsv_path = write_fixture("no-git", old_source, new_source, {
      {"cosmic/shift_test.tl", 1, "classA"},
      {"cosmic/shift_test.tl", 5, "classB"},
    }, false)
  local rows, unclassified = cast_sites.reconcile(root, tsv_path)
  assert(rows == nil, "expected reconcile to refuse, got rows")
  assert(#unclassified == 2,
    "expected 2 unclassified sites (no git history to compare against)"
    .. ", got " .. tostring(#unclassified))
end

-- One committed cast's exact text now appears on TWO working-tree
-- lines (the line was duplicated as well as shifted). The orphan side
-- is unique — only one committed row ever held that text — but the
-- newcomer side is not: uniqueness must hold on BOTH sides, so
-- neither of the two identical newcomers has a single line the class
-- is honestly for, and both stay unclassified rather than one of them
-- guessing the class that was never duplicated.
local function test_a_duplicated_newcomer_line_stays_unclassified()
  local old_source = table.concat({
      "local a = x as {string} -- cast: reason a",
      "local p = 1",
    }, "\n") .. "\n"
  local new_source = table.concat({
      "-- inserted",
      "local a = x as {string} -- cast: reason a",
      "local p = 1",
      "local a = x as {string} -- cast: reason a",
    }, "\n") .. "\n"
  local root, tsv_path = write_fixture("duplicated-newcomer", old_source,
    new_source, {
      {"cosmic/shift_test.tl", 1, "classA"},
    }, true)
  local rows, unclassified = cast_sites.reconcile(root, tsv_path)
  assert(rows == nil, "expected reconcile to refuse, got rows")
  assert(#unclassified == 2,
    "expected 2 unclassified sites, got " .. tostring(#unclassified))
  assert(unclassified[1] == "cosmic/shift_test.tl\t2"
    and unclassified[2] == "cosmic/shift_test.tl\t4",
    "unexpected unclassified keys: " .. table.concat(unclassified, ", "))
end

print("all cast site inventory tests passed")
