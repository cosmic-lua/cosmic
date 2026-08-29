#!/usr/bin/env cosmic
--- Tests for the perf gate's reproduction rule as a unit: the restore
--- half that demands a same-binary control explain a dismissal, and
--- `reconcile`, which runs it beside the strike-twice reclassification.
--- Results are fabricated in memory (and, for the path-taking calls, on
--- disk), so no benchmark runs.

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
  local encoded = json.encode(payload)
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
