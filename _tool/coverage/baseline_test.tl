#!/usr/bin/env cosmic
--- Tests for the coverage ratchet baseline.
local baseline = require("_tool.coverage.baseline")
local check = require("cosmic.check")
local floor = require("_tool.floor")
local fs = require("cosmic.fs")
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

--- One line for the parse-then-compare a render assertion usually needs.
local function assert_row(text: string, path: string, covered: integer, total: integer)
  local e = check.must(baseline.parse(text)).rows[path]
  assert(e and e.covered == covered and e.total == total,
    string.format("%s: want %d/%d, got %s", path, covered, total,
      e and (e.covered .. "/" .. e.total) or "missing"))
end

local function test_render_parse_roundtrip()
  local text = check.must(baseline.render(reports({
          {"lib/a.tl", 9, 10},
          {"lib/b.tl", 0, 5},
        })))
  assert_row(text, "lib/a.tl", 9, 10)
  assert_row(text, "lib/b.tl", 0, 5)
end
test_render_parse_roundtrip()

local function test_parse_rejects_malformed_input()
  local entries, err = baseline.parse("lib/a.tl nine ten\n")
  assert(entries == nil and err and err ~= "", "non-literal garbage must not parse")
  local bad, berr = baseline.parse('return {\n  ["a.tl"] = {covered = "nine", total = 10},\n}\n')
  assert(bad == nil and berr and berr:find("a.tl", 1, true),
    "a non-integer row must not parse, naming the bad row: " .. tostring(berr))
end
test_parse_rejects_malformed_input()

--- Compare current reports against a baseline built from the given rows.
local function violations(current: {{string, integer, integer}},
    base: {{string, integer, integer}}): {string}
  local text = check.must(baseline.render(reports(base)))
  local parsed = check.must(baseline.parse(text))
  return baseline.compare(reports(current), parsed.rows)
end

local function test_holds_when_unchanged_or_improved()
  local base = {{"lib/a.tl", 80, 100}, {"lib/b.tl", 5, 10}}
  assert(#violations({{"lib/a.tl", 80, 100}, {"lib/b.tl", 5, 10}}, base) == 0,
    "identical coverage must hold")
  assert(#violations({{"lib/a.tl", 95, 100}, {"lib/b.tl", 10, 10}}, base) == 0,
    "improved coverage must hold")
end
test_holds_when_unchanged_or_improved()

local function test_fails_on_file_decline_beyond_tolerance()
  local base = {{"lib/a.tl", 80, 100}}
  local probs = violations({{"lib/a.tl", 70, 100}}, base)
  assert(#probs == 2, "file and total decline expected, got " .. #probs)
  assert(probs[1]:find("lib/a%.tl"), "file violation should name the file")
end
test_fails_on_file_decline_beyond_tolerance()

local function test_small_decline_within_tolerance_holds()
  -- 1 line of 200 is a 0.5pp drop for the file (inside its 1.0pp
  -- slack) and 0.08pp of the 1200-line whole (inside the 0.2pp total
  -- tolerance): a flapping line must not trip either ratchet
  local base = {{"lib/a.tl", 180, 200}, {"lib/b.tl", 1000, 1000}}
  assert(#violations({{"lib/a.tl", 179, 200}, {"lib/b.tl", 1000, 1000}}, base) == 0,
    "one flapping line must not trip the ratchet")
end
test_small_decline_within_tolerance_holds()

local function test_tiny_file_gets_line_slack()
  -- 1 of 9 lines is an 11pp drop, but the two-line floor absorbs it
  local base = {{"lib/tiny.tl", 9, 9}, {"lib/big.tl", 900, 1000}}
  assert(#violations({{"lib/tiny.tl", 8, 9}, {"lib/big.tl", 900, 1000}}, base) == 0,
    "single line in a tiny file must not trip the ratchet")
end
test_tiny_file_gets_line_slack()

local function test_fails_on_file_set_drift()
  local base = {{"lib/a.tl", 8, 10}}
  local new_file = violations({{"lib/a.tl", 8, 10}, {"lib/new.tl", 4, 4}}, base)
  assert(#new_file == 1 and new_file[1]:find("not in baseline"),
    "new file must require a baseline update")
  local stale = violations({}, base)
  assert(#stale >= 1 and stale[1]:find("stale baseline entry"),
    "removed file must require a baseline update")
end
test_fails_on_file_set_drift()

local function test_total_ratchet_catches_masked_decline()
  -- Both files stay inside per-file slack, but the sum drops enough
  -- that the whole-tree ratchet still catches it. The baseline carries
  -- no total row, so this is the proof the DERIVED total gates exactly
  -- as strictly as a written one: nothing but the per-file rows above
  -- supplies the 4000/4000 it compares against.
  local base: {{string, integer, integer}} = {}
  local current: {{string, integer, integer}} = {}
  for i = 1, 20 do
    base[#base + 1] = {"lib/f" .. i .. ".tl", 200, 200}
    current[#current + 1] = {"lib/f" .. i .. ".tl", 198, 200}
  end
  local probs = violations(current, base)
  assert(#probs == 1 and probs[1]:find("^total"),
    "total ratchet should catch distributed decline, got " ..
    #probs .. ": " .. tostring(probs[1]))
  assert(probs[1]:find("100.0% -> 99.0% (3960/4000, baseline 4000/4000)", 1, true),
    "the message reports the summed baseline, got: " .. probs[1])
end
test_total_ratchet_catches_masked_decline()

local function test_gate_skips_under_only_filter()
  local code = baseline.gate("/no/such/baseline.txt", "sqlite", {})
  assert(code == 0, "gate must skip (exit 0) under an only= filter")
end
test_gate_skips_under_only_filter()

local function test_gate_skips_without_baseline()
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local code = baseline.gate(tmpdir .. "/absent-baseline.txt", "", {})
  assert(code == 0, "gate must skip (exit 0) when no baseline is committed")
end
test_gate_skips_without_baseline()

local function test_gate_checks_when_baseline_present()
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local path = fs.join(tmpdir, "gate-baseline.txt")
  assert(fs.write(path, check.must(baseline.render(reports({{"lib/a.tl", 9, 10}})))))
  -- an empty report set makes every baseline entry stale: the gate must
  -- delegate to check and FAIL, proving it does not skip when it
  -- should be checking
  local code = baseline.gate(path, "", {})
  assert(code == 1, "gate must run the real check when a baseline exists")
end
test_gate_checks_when_baseline_present()

-- `text_for` is what a caller that owns its output file needs: the
-- bytes, not a stream. `write` prints exactly these bytes, so the two
-- cannot disagree about the format -- and both refuse the same way when
-- there is no data to render.
local function test_text_for_returns_the_rendered_baseline()
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local empty = fs.join(tmpdir, "text-for-empty")
  assert(fs.make_dirs(empty))
  local text, err = baseline.text_for({empty})
  assert(not text, "no coverage data means no baseline: " .. tostring(text))
  assert(err and err ~= "", "and the refusal says why")
end
test_text_for_returns_the_rendered_baseline()

-- A rewrite that LOWERS a row is the one thing the ratchet cannot
-- object to, so `--baseline` says it out loud. Percentage, not raw
-- counts: a file that grew lines and covered more of them has not
-- lowered anything.
local function test_lowered_names_only_real_declines()
  local before = fixture({{"a.tl", 8, 10}, {"b.tl", 5, 10}, {"c.tl", 10, 10}})
  -- a.tl unchanged, b.tl lowered, c.tl grew but stayed 100%
  local after = fixture({{"a.tl", 8, 10}, {"b.tl", 3, 10}, {"c.tl", 12, 12}})
  local rows = baseline.lowered(before, after)
  assert(#rows == 1, "want only b.tl, got " .. #rows ..
    ": " .. table.concat(rows, "; "))
  assert(rows[1]:find("b.tl", 1, true), "got: " .. rows[1])
  assert(rows[1]:find("50.0% -> 30.0%", 1, true), "got: " .. rows[1])
end
test_lowered_names_only_real_declines()

-- A file the rewrite does not mention cannot have been lowered by it,
-- and a malformed baseline is not a decline report -- both answer with
-- nothing rather than guessing.
local function test_lowered_is_silent_when_it_cannot_tell()
  local before = fixture({{"gone.tl", 9, 10}})
  local after = fixture({})
  assert(#baseline.lowered(before, after) == 0,
    "a row the rewrite dropped is not a lowered row")
  assert(#baseline.lowered("nonsense", after) == 0,
    "an unparseable baseline reports nothing")
end
test_lowered_is_silent_when_it_cannot_tell()

-- The rewrite is ONE-WAY. `.cosmic-coverage` is a floor, and several rows were
-- set to what the strictest environment measures; a rebaseline from a
-- machine that measures more must not raise them, or CI fails on a row
-- nobody edited.
local function test_render_never_raises_a_committed_floor()
  local base_floor = check.must(baseline.parse(
      fixture({{"kept.tl", 4, 10}, {"worse.tl", 9, 10}, {"grown.tl", 8, 10}}))).rows
  local text = check.must(baseline.render(reports({
          -- measures better than its floor: the floor is kept verbatim
          {"kept.tl", 9, 10},
          -- measures worse: that is what a rebaseline is for
          {"worse.tl", 5, 10},
          -- more lines AND a better ratio: still not a reason to raise
          {"grown.tl", 11, 12},
          -- absent from the floor: recorded as measured
          {"new.tl", 3, 4},
        }), base_floor))
  assert_row(text, "kept.tl", 4, 10)
  assert_row(text, "worse.tl", 5, 10)
  assert_row(text, "grown.tl", 8, 10)
  assert_row(text, "new.tl", 3, 4)
end
test_render_never_raises_a_committed_floor()

-- A rewrite lowers a row only when the ratchet would have FAILED on it.
-- Everything else keeps the committed numbers, so a regeneration is a
-- near-empty diff: a percentage that held, a percentage that held while
-- the file grew, and a dip inside the per-file slack all leave the row
-- exactly as it was.
local function test_render_rewrites_only_rows_the_ratchet_would_fail()
  local before = fixture({{"flat.tl", 40, 50}, {"slack.tl", 180, 200}, {"real.tl", 180, 200}})
  local base_floor = check.must(baseline.parse(before)).rows
  local text = check.must(baseline.render(reports({
          -- 80% either way: identical percentage, different counts
          {"flat.tl", 44, 55},
          -- 0.5pp down, inside the file's 1.0pp slack
          {"slack.tl", 179, 200},
          -- 10pp down, well outside it: this is the one that moves
          {"real.tl", 160, 200},
        }), base_floor))
  assert_row(text, "flat.tl", 40, 50)
  assert_row(text, "slack.tl", 180, 200)
  assert_row(text, "real.tl", 160, 200)
  local moved = baseline.lowered(before, text)
  assert(#moved == 1, "only the failing row moved, got " .. #moved ..
    ": " .. table.concat(moved, "; "))
  assert(moved[1]:find("real.tl", 1, true), "got: " .. moved[1])
  assert(moved[1]:find("90.0% -> 80.0%", 1, true), "got: " .. moved[1])
end
test_render_rewrites_only_rows_the_ratchet_would_fail()

-- A tiny file's slack is two lines rather than a percentage, and the
-- rewrite reads the same slack the check does: one line of nine is a
-- 11pp drop the ratchet forgives, so the floor holds.
local function test_render_keeps_a_tiny_files_floor_within_its_line_slack()
  local base_floor = check.must(baseline.parse(fixture({{"tiny.tl", 9, 9}}))).rows
  local text = check.must(baseline.render(reports({{"tiny.tl", 8, 9}}), base_floor))
  assert_row(text, "tiny.tl", 9, 9)
end
test_render_keeps_a_tiny_files_floor_within_its_line_slack()

-- `.cosmic-coverage` merges with git's `union` strategy, so a row two
-- branches both edited arrives twice. The lower percentage wins: a
-- merge that RAISED a floor would fail CI on a decline neither side
-- introduced.
local function test_parse_resolves_a_duplicated_path_to_the_lower_coverage()
  local b = check.must(baseline.parse(
      fixture({{"a.tl", 9, 10}, {"a.tl", 4, 10}, {"b.tl", 1, 4}, {"b.tl", 9, 10}})))
  assert(b.rows["a.tl"].covered == 4, "later lower row wins, got " ..
    b.rows["a.tl"].covered)
  assert(b.rows["b.tl"].covered == 1 and b.rows["b.tl"].total == 4,
    "earlier lower row wins too")
  assert(b.duplicates == 2, "both repeats counted, got " .. b.duplicates)
end
test_parse_resolves_a_duplicated_path_to_the_lower_coverage()

-- Two rows can tie on percentage, so the resolution has to keep going.
-- The smaller line universe wins first: 1/2 and 2/4 are both 50%, and
-- the 2-line row is the one a check would measure against.
local function test_parse_breaks_a_percentage_tie_on_the_smaller_universe()
  local b = check.must(baseline.parse(fixture({{"a.tl", 1, 2}, {"a.tl", 2, 4}})))
  assert(b.rows["a.tl"].total == 2 and b.rows["a.tl"].covered == 1,
    "smaller universe wins, got " .. b.rows["a.tl"].covered .. "/" ..
    b.rows["a.tl"].total)
  local flipped = check.must(baseline.parse(fixture({{"a.tl", 2, 4}, {"a.tl", 1, 2}})))
  assert(flipped.rows["a.tl"].total == 2,
    "and wins from the other side too, got " .. flipped.rows["a.tl"].total)
end
test_parse_breaks_a_percentage_tie_on_the_smaller_universe()

-- Two branches can each append the same new row, in regions far enough
-- apart that the merge keeps both copies. Nothing distinguishes them,
-- and the resolution still has to answer: the row survives intact and
-- is counted as the repeat it is.
local function test_parse_resolves_identical_duplicate_rows()
  local b = check.must(baseline.parse(fixture({{"a.tl", 9, 10}, {"a.tl", 9, 10}})))
  assert(b.rows["a.tl"].covered == 9 and b.rows["a.tl"].total == 10,
    "identical rows resolve to themselves")
  assert(b.duplicates == 1, "and are still a duplicate, got " .. b.duplicates)
end
test_parse_resolves_identical_duplicate_rows()

-- A freshly rendered baseline has nothing to resolve, and the count
-- says so rather than being absent.
local function test_parse_counts_no_duplicates_in_a_clean_baseline()
  local b = check.must(baseline.parse(fixture({{"a.tl", 9, 10}, {"b.tl", 1, 4}})))
  assert(b.duplicates == 0, "clean baseline, got " .. b.duplicates)
end
test_parse_counts_no_duplicates_in_a_clean_baseline()

-- With no floor to compare against, render records what it measured.
local function test_render_without_a_floor_records_the_run()
  local text = check.must(baseline.render(reports({{"a.tl", 9, 10}})))
  assert_row(text, "a.tl", 9, 10)
end
test_render_without_a_floor_records_the_run()

-- What a failing ratchet SAYS, which is the half nobody was testing:
-- `gate` returning 1 was asserted, the report it prints on the way was
-- not -- a floor that moved and will not say which row is a gate you
-- have to re-run to read. The LAST line matters most: a failing
-- `--make ci` ends with a stage verdict hundreds of lines back from
-- the per-file report, so one line naming every declining file,
-- printed last, is what survives a truncated view.
local function test_a_failing_ratchet_names_the_rows_that_moved()
  local child = require("cosmic.child")
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local root = fs.join(tmpdir, "ratchet-says")
  assert(fs.remove_all(root))
  assert(fs.make_dirs(fs.join(root, "lib")))
  local src = fs.join(root, "lib/a.tl")
  assert(fs.write(src, "local x = 1\nlocal y = 2\nreturn x + y\n"))
  -- One real `.cov`, because compute refuses a run with none; the
  -- source scan is what supplies the zero-coverage row that declines.
  assert(fs.write(fs.join(root, "one.cov"),
      '{version=1,hits={["' .. src .. '"]={[1]=1}}}'))
  local floor_path = fs.join(root, "floor")
  assert(fs.write(floor_path, fixture({{src, 3, 3}})))

  -- A child, because the report goes to this process's stderr.
  local cosmic = fs.join(os.getenv("TEST_BIN") or "", "cosmic")
  check.needs("a built cosmic at " .. cosmic, fs.is_file(cosmic))
  -- A SCRIPT file, not `-e`: only the script path arms line coverage,
  -- so a `-e` child runs the code under test and reports none of it.
  local script = fs.join(root, "run.lua")
  assert(fs.write(script,
      'os.exit(require("_tool.coverage.baseline").gate(' ..
      string.format("%q", floor_path) .. ', "", {' ..
      string.format("%q", root) .. '}))\n'))
  local r = check.must(child.run({cosmic, script}))
  local err = r.stderr or ""
  assert(r.code == 1, "a declining floor must fail, got " .. tostring(r.code))
  assert(err:find("coverage declined 100.0% -> 0.0%", 1, true),
    "the per-file line names what moved, got: " .. err)
  local last = err:match("([^\n]+)\n?$") or ""
  assert(last:find("coverage ratchet: declined: ", 1, true),
    "the one-line summary must be LAST, got: " .. last)
  assert(last:find(src, 1, true),
    "and must name every declining file, got: " .. last)
end
test_a_failing_ratchet_names_the_rows_that_moved()

--- A directory `report.compute` can read: one source file with three
--- executable lines and one `.cov` file (compute refuses a run with no
--- coverage data), measuring 0 of 3.
--- @param name string Subdirectory of TEST_TMPDIR to build it in
--- @return string The fixture root
--- @return string The display path its one row carries
local function coverage_fixture(name: string): string, string
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local root = fs.join(tmpdir, name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(fs.join(root, "lib")))
  local src = fs.join(root, "lib/a.tl")
  assert(fs.write(src, "local x = 1\nlocal y = 2\nreturn x + y\n"))
  assert(fs.write(fs.join(root, "one.cov"),
      '{version=1,hits={["' .. src .. '"]={[1]=1}}}'))
  return root, src
end

-- The two ways `check` refuses before it can compare anything: no
-- baseline to read, and a baseline it cannot parse. Both are exit 1
-- with the reason on stderr, so a gate never reports "ok" for a
-- comparison it did not make.
local function test_check_refuses_an_unreadable_or_malformed_baseline()
  local root, _src = coverage_fixture("ratchet-refuses")
  assert(baseline.check(fs.join(root, "absent"), {root}) == 1,
    "a baseline that cannot be read is not a pass")
  local garbage = fs.join(root, "garbage")
  assert(fs.write(garbage, "lib/a.tl nine ten\n"))
  assert(baseline.check(garbage, {root}) == 1,
    "a baseline that cannot be parsed is not a pass")
end
test_check_refuses_an_unreadable_or_malformed_baseline()

-- A merged baseline gates against the RESOLVED rows and says so. The
-- duplicate note and the `ok` line land on this test's own streams,
-- which is the price of exercising the real function rather than a
-- child whose coverage nobody collects.
local function test_check_gates_against_the_resolved_rows()
  local root, src = coverage_fixture("ratchet-resolved")
  -- The run measures 0 of 3. The high row alone would fail the ratchet;
  -- the low one is the floor that holds, so a pass here is the proof
  -- that the lower row is what gated.
  local floor_path = fs.join(root, "floor")
  assert(fs.write(floor_path, fixture({{src, 3, 3}, {src, 0, 3}})))
  assert(baseline.check(floor_path, {root}) == 0,
    "the lower duplicate row is the floor, and it holds")
  -- Without the low row the same run fails, which is what makes the
  -- assertion above about resolution rather than about slack.
  local high = fs.join(root, "high")
  assert(fs.write(high, fixture({{src, 3, 3}})))
  assert(baseline.check(high, {root}) == 1,
    "the high row on its own is a decline")
end
test_check_gates_against_the_resolved_rows()

-- A merged baseline still gates, and does not do it quietly. A `union`
-- merge leaves duplicate rows behind; the check reads them (resolved to
-- the lower coverage) and names them on stderr, so the file's untidy
-- state is visible in the run that tolerated it rather than surviving
-- unnoticed until someone opens the diff.
local function test_check_gates_a_merged_baseline_and_names_the_duplicates()
  local child = require("cosmic.child")
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local root = fs.join(tmpdir, "ratchet-merged")
  assert(fs.remove_all(root))
  assert(fs.make_dirs(fs.join(root, "lib")))
  assert(fs.write(fs.join(root, "lib/a.tl"),
      "local x = 1\nlocal y = 2\nreturn x + y\n"))
  -- Paths inside the .cov are relative, so the child runs WITH `root`
  -- as its cwd: that is what lets the collector's chunk name and the
  -- source scan agree on one display path.
  assert(fs.write(fs.join(root, "one.cov"),
      '{version=1,hits={["@lib/a.tl"]={[1]=1,[2]=1,[3]=1}}}'))
  -- The same path twice, as a union merge of two edits leaves it. The
  -- lower row (2/3) is the floor that gates; the run measures 3/3, so
  -- the ratchet holds.
  local floor_path = fs.join(root, "floor")
  assert(fs.write(floor_path, fixture({{"lib/a.tl", 3, 3}, {"lib/a.tl", 2, 3}})))

  -- Absolute, because the child runs with `root` as its cwd and TEST_BIN
  -- is relative to the repo root.
  local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN") or "", "cosmic"))
  check.needs("a built cosmic at " .. cosmic, fs.is_file(cosmic))
  local script = fs.join(root, "run.lua")
  assert(fs.write(script,
      'os.exit(require("_tool.coverage.baseline").gate("floor", "", ' ..
      '{"one.cov", "lib"}))\n'))
  local r = check.must(child.run({cosmic, script}, {cwd = root}))
  local err = r.stderr or ""
  assert(r.code == 0, "a merged baseline must still hold, got " ..
    tostring(r.code) .. ": " .. err)
  assert((r.stdout or ""):find("coverage ratchet ok", 1, true),
    "the ratchet holds, got: " .. tostring(r.stdout))
  assert(err:find("1 duplicate row(s), resolved to the lower coverage", 1, true),
    "the duplicate rows must be named, got: " .. err)
end
test_check_gates_a_merged_baseline_and_names_the_duplicates()

-- The migration this slice performs: `.cosmic-coverage` moved from
-- "path covered total" lines to a `cosmic.literal` table, byte for
-- byte the same data. BOTH sides are frozen fixtures, because the
-- migration is a one-time fact between two texts while the live floor's
-- rows move with every rebaseline — reading it here would pin today's
-- file and fail the next run that adds a source file. This test is the
-- old format's LAST reader: it reproduces the deleted line-scan itself.
local function test_migration_preserves_every_row()
  local dir = "_tool/coverage/testdata/"
  local old_text = check.must(fs.read(dir .. "pre_literal_baseline.txt"))
  local new_rows = check.must(floor.parse(
      check.must(fs.read(dir .. "post_literal_baseline.txt"))))
  local old_count, new_count = 0, 0
  for _ in pairs(new_rows) do new_count = new_count + 1 end
  for line in old_text:gmatch("[^\n]+") do
    if not line:match("^#") then
      local path, covered, total = line:match("^(%S+) (%d+) (%d+)$")
      if path then
        old_count = old_count + 1
        local got = new_rows[path] as {string: any} -- cast: literal row, known Entry shape
        assert(got and got.covered == tonumber(covered) and got.total == tonumber(total),
          "row moved or missing during migration: " .. path)
      end
    end
  end
  assert(old_count == 249, "fixture row count drifted, got " .. old_count)
  assert(new_count == old_count,
    "row count changed during migration: " .. old_count .. " -> " .. new_count)
end
test_migration_preserves_every_row()

print("all baseline tests passed")
