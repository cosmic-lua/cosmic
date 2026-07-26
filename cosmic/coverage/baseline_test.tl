#!/usr/bin/env cosmic
--- Tests for the coverage ratchet baseline.
local baseline = require("cosmic.coverage.baseline")
local check = require("cosmic.check")
local rep = require("cosmic.coverage.report")

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
  local entries, total, err = baseline.parse(text)
  local e = check.must(entries, err)
  assert(e["lib/a.tl"].covered == 9 and e["lib/a.tl"].total == 10, "row a lost")
  assert(e["lib/b.tl"].covered == 0 and e["lib/b.tl"].total == 5, "row b lost")
  assert(total and total.covered == 9 and total.total == 15, "total row wrong")
end
test_render_parse_roundtrip()

local function test_parse_rejects_garbage()
  local entries, _, err = baseline.parse("lib/a.tl nine ten\n")
  assert(entries == nil, "garbage row must not parse")
  assert(err and err:find("line 1"), "error should name the line: " .. tostring(err))
end
test_parse_rejects_garbage()

--- Compare current reports against a baseline built from the given rows.
local function violations(current: {{string, integer, integer}},
    base: {{string, integer, integer}}): {string}
  local text = baseline.render(reports(base))
  local entries, total = baseline.parse(text)
  return baseline.compare(reports(current),
    check.must(entries), total)
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
  -- both files stay inside per-file slack, but the sum drops enough
  -- that the total row still catches it
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
  assert(fs.makedirs(empty))
  local text, err = baseline.text_for({empty})
  assert(not text, "no coverage data means no baseline: " .. tostring(text))
  assert(err and err ~= "", "and the refusal says why")
end
test_text_for_returns_the_rendered_baseline()

print("all baseline tests passed")
