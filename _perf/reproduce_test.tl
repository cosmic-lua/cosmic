#!/usr/bin/env cosmic
--- Tests for the perf gate's reproduction rule as a unit: the restore
--- half that demands a same-binary control explain a dismissal, and
--- `reconcile`, which runs it beside the strike-twice reclassification.
--- Results are fabricated in memory (and, for the path-taking calls, on
--- disk), so no benchmark runs.

local check = require("cosmic.check")
local compare = require("_perf.compare")
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local pt = require("_perf.perf_types")
local reproduce = require("_perf.reproduce")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- One results value, one scenario per parallel (name, wall_ns) entry.
local function results(names: {string}, wall: {number}): pt.Results
  local rows: {pt.Measurement} = {}
  for i, name in ipairs(names) do
    rows[#rows + 1] = {name = name, wall_ns = wall[i], spread_pct = 2}
  end
  return {results = rows}
end

--- The same value on disk, for the calls that take paths.
local function write_results(path: string, names: {string}, wall: {number})
  local rows: {{string: any}} = {}
  for i, name in ipairs(names) do
    rows[#rows + 1] = {name = name, wall_ns = wall[i], spread_pct = 2}
  end
  local payload: {string: any} = {meta = {bin_sha = "bbbb2222"}, results = rows}
  local encoded = check.must(json.encode(payload))
  assert(fs.write(path, encoded))
end

--- A pass-1 flag: the delta that read over the bar.
local function flag(name: string, delta_pct: number): pt.Delta
  return {name = name, verdict = "regression", delta_pct = delta_pct,
    noise_pct = 10, base_ns = 1000, cur_ns = 1000}
end

--- A pass-2 row that read under the bar.
local function quiet(name: string, delta_pct: number): pt.Delta
  return {name = name, verdict = "ok", delta_pct = delta_pct,
    noise_pct = 10, base_ns = 1000, cur_ns = 1000}
end

-- Two current-side samples that agree the scenario is up, one of them
-- merely under the bar, and controls that read quiet: nothing explains
-- the disagreement, so the dismissal is amended back to a regression.
local function test_an_unexplained_dismissal_is_restored()
  local deltas = {quiet("a", 9.0)}
  local msgs = reproduce.restore(deltas, {a = flag("a", 12.0)},
    {results({"a"}, {1000}), results({"a"}, {1000})}, 10)
  assert(deltas[1].verdict == "regression",
    "an unexplained dismissal must be restored, got " .. deltas[1].verdict)
  assert(#msgs == 1, "expected one message, got " .. #msgs)
  assert(msgs[1]:find("no same-binary", 1, true),
    "the message must say what is missing, got " .. msgs[1])
end

-- ...and the loud, genuinely non-reproducing dismissal is absorbed
-- exactly as before: the control pair swings 30%, which at TRIAGE_K = 2
-- credits far more than the 12% pass 1 flagged.
local function test_a_dismissal_the_controls_explain_stands()
  local deltas = {quiet("a", 9.0)}
  local msgs = reproduce.restore(deltas, {a = flag("a", 12.0)},
    {results({"a"}, {1000}), results({"a"}, {1300})}, 10)
  assert(deltas[1].verdict == "ok",
    "an explained dismissal must stand, got " .. deltas[1].verdict)
  assert(#msgs == 0, "expected no message, got " .. #msgs)
end

-- Fewer than two controls is no pair and no credit, which is a
-- dismissal with no evidence behind it.
local function test_a_dismissal_with_no_control_pair_is_restored()
  local deltas = {quiet("a", 9.0)}
  local msgs = reproduce.restore(deltas, {a = flag("a", 12.0)},
    {results({"a"}, {1000})}, 10)
  assert(deltas[1].verdict == "regression",
    "no control pair is no evidence, got " .. deltas[1].verdict)
  assert(#msgs == 1, "expected one message, got " .. #msgs)
end

-- The messages follow the deltas' array order, not a hash order, so the
-- printed record reads the same on every run.
local function test_messages_follow_delta_order()
  local deltas = {quiet("z", 9.0), quiet("m", 9.0), quiet("a", 9.0)}
  local flagged: {string: pt.Delta} =
  {z = flag("z", 12.0), m = flag("m", 12.0), a = flag("a", 12.0)}
  local msgs = reproduce.restore(deltas, flagged,
    {results({"z"}, {1000}), results({"z"}, {1000})}, 10)
  assert(#msgs == 3, "expected three messages, got " .. #msgs)
  assert(msgs[1]:find("perf-compare: z ", 1, true), "first is z, got " .. msgs[1])
  assert(msgs[2]:find("perf-compare: m ", 1, true), "second is m, got " .. msgs[2])
  assert(msgs[3]:find("perf-compare: a ", 1, true), "third is a, got " .. msgs[3])
end

-- Only a quiet READING is a dismissal. A row that errored, went
-- missing, or could not be diffed fails on its own in whichever pass it
-- appears, and the rule must not overwrite that verdict with one the
-- gate would report differently.
local function test_a_failing_verdict_is_never_rewritten()
  for _, v in ipairs({"missing", "error", "baseline-error", "malformed"}) do
    local d = quiet("a", 9.0)
    d.verdict = v
    local deltas = {d}
    local msgs = reproduce.restore(deltas, {a = flag("a", 12.0)},
      {results({"a"}, {1000}), results({"a"}, {1000})}, 10)
    assert(deltas[1].verdict == v, v .. " must stand, got " .. deltas[1].verdict)
    assert(#msgs == 0, "expected no message for " .. v .. ", got " .. #msgs)
  end
end

-- reconcile's first half is the strike-twice rule, unchanged: a
-- regression pass 1 did not flag appeared only in the retry.
local function test_reconcile_reclassifies_a_regression_pass_1_missed()
  local a = fs.join(tmpdir, "rec-a.json")
  local b = fs.join(tmpdir, "rec-b.json")
  write_results(a, {"b"}, {1000})
  write_results(b, {"b"}, {1000})
  local d = flag("b", 30.0)
  local deltas = {d}
  local msgs, change = reproduce.reconcile(deltas, {}, {a, b}, 10, true)
  assert(deltas[1].verdict == "noise",
    "a strike-once regression is noise, got " .. deltas[1].verdict)
  assert(change == -1, "expected one failure removed, got " .. change)
  assert(#msgs == 1 and msgs[1]:find("only in the retry", 1, true),
    "expected the strike-once message, got " .. #msgs)
end

-- Two current-side samples are comparable to each other only when they
-- measured the same binary; with same_side false the restore half is
-- off and a dismissal stands with no control consulted.
local function test_reconcile_skips_the_restore_across_binaries()
  local a = fs.join(tmpdir, "rec-cross-a.json")
  local b = fs.join(tmpdir, "rec-cross-b.json")
  write_results(a, {"a"}, {1000})
  write_results(b, {"a"}, {1000})
  local deltas = {quiet("a", 9.0)}
  local msgs, change =
  reproduce.reconcile(deltas, {a = flag("a", 12.0)}, {a, b}, 10, false)
  assert(deltas[1].verdict == "ok",
    "same_side false turns the rule off, got " .. deltas[1].verdict)
  assert(change == 0, "expected no change, got " .. change)
  assert(#msgs == 0, "expected no message, got " .. #msgs)
end

-- Both halves in one call, and they net out: one regression drops to
-- noise, one dismissal is restored.
local function test_reconcile_runs_both_halves()
  local a = fs.join(tmpdir, "rec-both-a.json")
  local b = fs.join(tmpdir, "rec-both-b.json")
  write_results(a, {"a", "b"}, {1000, 1000})
  write_results(b, {"a", "b"}, {1000, 1000})
  local deltas = {quiet("a", 9.0), flag("b", 30.0)}
  local msgs, change =
  reproduce.reconcile(deltas, {a = flag("a", 12.0)}, {a, b}, 10, true)
  assert(deltas[1].verdict == "regression",
    "the dismissal is restored, got " .. deltas[1].verdict)
  assert(deltas[2].verdict == "noise",
    "the strike-once regression is noise, got " .. deltas[2].verdict)
  assert(change == 0, "one removed and one added nets zero, got " .. change)
  assert(#msgs == 2, "expected both messages, got " .. #msgs)
end

-- A control path that will not load is dropped rather than refused: it
-- only removes noise credit, and the file is the next call's error to
-- report in its own words.
local function test_an_unloadable_control_path_is_dropped()
  local a = fs.join(tmpdir, "rec-missing-a.json")
  write_results(a, {"a"}, {1000})
  local deltas = {quiet("a", 9.0)}
  local msgs = reproduce.restore_paths(deltas, {a = flag("a", 12.0)},
    {a, fs.join(tmpdir, "rec-nope.json")}, 10)
  assert(deltas[1].verdict == "regression",
    "a dropped control leaves no credit, got " .. deltas[1].verdict)
  assert(#msgs == 1, "expected one message, got " .. #msgs)
end

--- Drive the real rule at one point of the (f, r) plane, exactly as
--- `gate_inner` does: pass 1 reads the scenario up by `f` percent over
--- the baseline, the retry up by `r`, and those two current-side
--- samples ARE the control pair. True when the dismissal was restored.
local function restored_at(f: number, r: number): boolean
  local base = results({"a"}, {1000.0})
  local cur = results({"a"}, {1000.0 * (1.0 + f / 100.0)})
  local retry = results({"a"}, {1000.0 * (1.0 + r / 100.0)})
  local flagged: {string: pt.Delta} = {}
  for _, d in ipairs((compare.diff(base, cur, 10))) do
    if d.verdict == "regression" then
      flagged[d.name] = d
    end
  end
  local deltas = (compare.diff(base, retry, 10))
  reproduce.restore(deltas, flagged, {cur, retry}, 10)
  return deltas[1].verdict == "regression"
end

--- The lowest `f` in (lo, hi] whose outcome differs from `lo`'s, to the
--- precision 50 bisections buy. Both endpoints must already disagree.
local function edge(lo: number, hi: number, r: number): number
  local want = restored_at(lo, r)
  assert(restored_at(hi, r) ~= want, "bisection endpoints must disagree")
  for _ = 1, 50 do
    local mid = (lo + hi) / 2.0
    if restored_at(mid, r) == want then
      lo = mid
    else
      hi = mid
    end
  end
  return hi
end

-- The region the restore ACTUALLY fires in, point by point, so the
-- prose in this module and in D35 cannot drift from the code. Note the
-- two shapes an intuitive reading gets wrong and these points pin: the
-- unbounded upper arm (a loud, genuinely non-reproducing dismissal is
-- restored, 75/10 and 300/0), and the non-monotonicity in `r` (15/0, a
-- retry all the way back to baseline, is absorbed where the weaker
-- refutation 15/5 is restored).
local function test_the_firing_region_is_where_the_record_says()
  -- {f, r, 1 = restored / 0 = absorbed}
  local points: {{number}} = {
    {11.0, 0.0, 1}, {12.0, 0.0, 0}, {15.0, 0.0, 0}, {50.0, 0.0, 0},
    {100.0, 0.0, 0}, {300.0, 0.0, 1},
    {15.0, 5.0, 1}, {20.0, 5.0, 0}, {88.0, 5.0, 0}, {100.0, 5.0, 1},
    {20.0, 9.0, 1}, {25.0, 9.0, 0},
    {25.0, 10.0, 1}, {27.5, 10.0, 1}, {30.0, 10.0, 0}, {50.0, 10.0, 0},
    {75.0, 10.0, 1},
  }
  for _, p in ipairs(points) do
    local want = p[3] == 1
    local got = restored_at(p[1], p[2])
    assert(got == want, string.format("f=%.1f%% r=%.1f%%: expected %s, got %s",
        p[1], p[2], want and "restored" or "absorbed",
        got and "restored" or "absorbed"))
  end
end

-- ...and the edges of that region, bisected on the real code. The
-- absorbed band is [L(r), U(r)] with
-- L(r) = max((N + r)/(1 - N), (1 - sqrt(1 - 8r))/2) and
-- U(r) = (1 + sqrt(1 - 8r))/2, r and N as fractions. Any move in the
-- credit rule -- TRIAGE_K, the noise bar, or crediting an under-bar
-- control pair -- moves these numbers and fails here.
local function test_the_region_edges_are_where_the_record_says()
  -- {r, L(r), U(r)}, percent
  local bands: {{number}} = {
    {0.0, 11.1111, 100.0000},
    {2.5, 13.8889, 94.7214},
    {5.0, 16.6667, 88.7298},
    {7.5, 19.4444, 81.6228},
    {9.0, 23.5425, 76.4575},
    {10.0, 27.6393, 72.3607},
  }
  for _, b in ipairs(bands) do
    local lo = edge(10.001, 60.0, b[1])
    local hi = edge(60.0, 400.0, b[1])
    assert(math.abs(lo - b[2]) < 0.001,
      string.format("r=%.1f%%: L is %.4f%%, want %.4f%%", b[1], lo, b[2]))
    assert(math.abs(hi - b[3]) < 0.001,
      string.format("r=%.1f%%: U is %.4f%%, want %.4f%%", b[1], hi, b[3]))
  end
end
