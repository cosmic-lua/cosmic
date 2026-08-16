#!/usr/bin/env cosmic
--- Tests for the coverage ratchet baseline.
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

local function test_render_parse_roundtrip()
  local text = baseline.render(reports({
        {"lib/a.tl", 9, 10},
        {"lib/b.tl", 0, 5},
      }))
  local parsed, err = baseline.parse(text)
  local b = check.must(parsed, err)
  local e = b.rows
  assert(e["lib/a.tl"].covered == 9 and e["lib/a.tl"].total == 10, "row a lost")
  assert(e["lib/b.tl"].covered == 0 and e["lib/b.tl"].total == 5, "row b lost")
  -- The whole-tree total is DERIVED from the rows above, never written:
  -- a committed total row is rewritten by every regeneration, so two
  -- PRs with disjoint per-file rows still conflict on that one line.
  assert(not text:find("\ntotal ", 1, true), "no total row is written:\n" .. text)
  assert(b.total == nil, "and none is parsed back")
end
test_render_parse_roundtrip()

-- A baseline still CARRYING a total row parses, so a branch cut before
-- the row went away keeps working; the row is simply not read.
local function test_parse_tolerates_a_legacy_total_row()
  local b = check.must(baseline.parse("# h\n# c\nlib/a.tl 9 10\ntotal 9 10\n"))
  assert(b.rows["lib/a.tl"].covered == 9, "per-file row lost")
  assert(b.total and b.total.covered == 9, "legacy total row must still parse")
end
test_parse_tolerates_a_legacy_total_row()

local function test_parse_rejects_garbage()
  local entries, err = baseline.parse("lib/a.tl nine ten\n")
  assert(entries == nil, "garbage row must not parse")
  assert(err and err:find("line 1"), "error should name the line: " .. tostring(err))
end
test_parse_rejects_garbage()

--- Compare current reports against a baseline built from the given rows.
local function violations(current: {{string, integer, integer}},
    base: {{string, integer, integer}}): {string}
  local text = baseline.render(reports(base))
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
  local fs = require("cosmic.fs")
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local path = fs.join(tmpdir, "gate-baseline.txt")
  assert(fs.write(path, baseline.render(reports({{"lib/a.tl", 9, 10}}))))
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
  local fs = require("cosmic.fs")
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
  local before = "# h\n# c\n" ..
  "a.tl 8 10\n" ..
  "b.tl 5 10\n" ..
  "c.tl 10 10\n" ..
  "total 23 30\n"
  local after = "# h\n# c\n" ..
  "a.tl 8 10\n" .. -- unchanged
  "b.tl 3 10\n" .. -- lowered
  "c.tl 12 12\n" .. -- grew, still 100%
  "total 23 32\n" -- lowered as a percentage
  local rows = baseline.lowered(before, after)
  assert(#rows == 2, "want b.tl and total, got " .. #rows ..
    ": " .. table.concat(rows, "; "))
  assert(rows[1]:find("b.tl", 1, true), "got: " .. rows[1])
  assert(rows[1]:find("50.0% -> 30.0%", 1, true), "got: " .. rows[1])
  assert(rows[2]:find("total", 1, true), "got: " .. rows[2])
end
test_lowered_names_only_real_declines()

-- A file the rewrite does not mention cannot have been lowered by it,
-- and a malformed baseline is not a decline report -- both answer with
-- nothing rather than guessing.
local function test_lowered_is_silent_when_it_cannot_tell()
  local before = "# h\n# c\ngone.tl 9 10\ntotal 9 10\n"
  local after = "# h\n# c\ntotal 9 10\n"
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
  local floor = check.must(baseline.parse(
      "# h\n# c\nkept.tl 4 10\nworse.tl 9 10\ngrown.tl 8 10\n")).rows
  local text = baseline.render(reports({
        -- measures better than its floor: the floor is kept verbatim
        {"kept.tl", 9, 10},
        -- measures worse: that is what a rebaseline is for
        {"worse.tl", 5, 10},
        -- more lines AND a better ratio: still not a reason to raise
        {"grown.tl", 11, 12},
        -- absent from the floor: recorded as measured
        {"new.tl", 3, 4},
      }), floor)
  assert(text:find("\nkept.tl 4 10\n", 1, true), "got:\n" .. text)
  assert(text:find("\nworse.tl 5 10\n", 1, true), "got:\n" .. text)
  assert(text:find("\ngrown.tl 8 10\n", 1, true), "got:\n" .. text)
  assert(text:find("\nnew.tl 3 4\n", 1, true), "got:\n" .. text)
  assert(not text:find("\ntotal ", 1, true), "and no total row:\n" .. text)
end
test_render_never_raises_a_committed_floor()

-- A rewrite lowers a row only when the ratchet would have FAILED on it.
-- Everything else keeps the committed numbers, so a regeneration is a
-- near-empty diff: a percentage that held, a percentage that held while
-- the file grew, and a dip inside the per-file slack all leave the row
-- exactly as it was.
local function test_render_rewrites_only_rows_the_ratchet_would_fail()
  local floor = check.must(baseline.parse(
      "# h\n# c\nflat.tl 40 50\nslack.tl 180 200\nreal.tl 180 200\n")).rows
  local text = baseline.render(reports({
        -- 80% either way: identical percentage, different counts
        {"flat.tl", 44, 55},
        -- 0.5pp down, inside the file's 1.0pp slack
        {"slack.tl", 179, 200},
        -- 10pp down, well outside it: this is the one that moves
        {"real.tl", 160, 200},
      }), floor)
  assert(text:find("\nflat.tl 40 50\n", 1, true), "got:\n" .. text)
  assert(text:find("\nslack.tl 180 200\n", 1, true), "got:\n" .. text)
  assert(text:find("\nreal.tl 160 200\n", 1, true), "got:\n" .. text)
  local moved = baseline.lowered(
    "# h\n# c\nflat.tl 40 50\nslack.tl 180 200\nreal.tl 180 200\n", text)
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
  local floor = check.must(baseline.parse("# h\n# c\ntiny.tl 9 9\n")).rows
  local text = baseline.render(reports({{"tiny.tl", 8, 9}}), floor)
  assert(text:find("\ntiny.tl 9 9\n", 1, true), "got:\n" .. text)
end
test_render_keeps_a_tiny_files_floor_within_its_line_slack()

-- `.cosmic-coverage` merges with git's `union` strategy, so a row two
-- branches both edited arrives twice. The lower percentage wins: a
-- merge that RAISED a floor would fail CI on a decline neither side
-- introduced.
local function test_parse_resolves_a_duplicated_path_to_the_lower_coverage()
  local b = check.must(baseline.parse(
      "# h\n# c\n" ..
      "a.tl 9 10\n" ..
      "a.tl 4 10\n" ..
      "b.tl 1 4\n" ..
      "b.tl 9 10\n"))
  assert(b.rows["a.tl"].covered == 4, "later lower row wins, got " ..
    b.rows["a.tl"].covered)
  assert(b.rows["b.tl"].covered == 1 and b.rows["b.tl"].total == 4,
    "earlier lower row wins too")
  assert(b.duplicates == 2, "both repeats counted, got " .. b.duplicates)
end
test_parse_resolves_a_duplicated_path_to_the_lower_coverage()

-- A freshly rendered baseline has nothing to resolve, and the count
-- says so rather than being absent.
local function test_parse_counts_no_duplicates_in_a_clean_baseline()
  local b = check.must(baseline.parse("# h\n# c\na.tl 9 10\nb.tl 1 4\n"))
  assert(b.duplicates == 0, "clean baseline, got " .. b.duplicates)
end
test_parse_counts_no_duplicates_in_a_clean_baseline()

-- With no floor to compare against, render records what it measured.
local function test_render_without_a_floor_records_the_run()
  local text = baseline.render(reports({{"a.tl", 9, 10}}))
  assert(text:find("\na.tl 9 10\n", 1, true), "got:\n" .. text)
end
test_render_without_a_floor_records_the_run()

-- What a failing ratchet SAYS, which is the half nobody was testing:
-- `gate` returning 1 was asserted, the report it prints on the way was
-- not. That report is the whole value of the gate — a floor that moved
-- and will not say which row is a gate you have to re-run to read.
--
-- The last line matters most and is the reason it exists. A failing
-- `--make ci` ends with 166 test results and a stage verdict, so the
-- per-file lines are hundreds back and fall out of any truncated view;
-- one line naming every declining file, printed last, survives that.
local function test_a_failing_ratchet_names_the_rows_that_moved()
  local fs = require("cosmic.fs")
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
  local floor = fs.join(root, "floor")
  assert(fs.write(floor, src .. " 3 3\n"))

  -- A child, because the report goes to this process's stderr.
  local cosmic = fs.join(os.getenv("TEST_BIN") or "", "cosmic")
  check.needs("a built cosmic at " .. cosmic, fs.is_file(cosmic))
  -- A SCRIPT file, not `-e`: only the script path arms line coverage,
  -- so a `-e` child runs the code under test and reports none of it.
  local script = fs.join(root, "run.lua")
  assert(fs.write(script,
      'os.exit(require("_tool.coverage.baseline").gate(' ..
      string.format("%q", floor) .. ', "", {' ..
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

-- A merged baseline still gates, and does not do it quietly. A `union`
-- merge leaves duplicate rows behind; the check reads them (resolved to
-- the lower coverage) and names them on stderr, so the file's untidy
-- state is visible in the run that tolerated it rather than surviving
-- unnoticed until someone opens the diff.
local function test_check_gates_a_merged_baseline_and_names_the_duplicates()
  local fs = require("cosmic.fs")
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
  local floor = fs.join(root, "floor")
  assert(fs.write(floor, "# h\nlib/a.tl 3 3\nlib/a.tl 2 3\n"))

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

print("all baseline tests passed")
