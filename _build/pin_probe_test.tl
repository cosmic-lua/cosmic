--- reads: o/bootstrap/cosmic
--- Guard for the pin probe's judgement.
---
--- `verdict` is the whole judgement, so the four exit-status pairs are
--- tested exactly, including the one the pin-bump procedure kept
--- getting wrong: two refusals with different messages is VACUOUS.
---
--- The end-to-end tests run the pinned bootstrap as BOTH the baseline
--- and the candidate, so the answer is a VACUOUS one either way. That
--- is deliberate: both outcomes hold under any checker, patched or
--- not, so neither test can rot with a pin bump. The DISCRIMINATES
--- arms need two binaries that actually differ — a pre-patch release
--- and a post-patch one — which this tree does not carry, so they are
--- covered by the pure `verdict` tests only.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local pin_probe = require("_build.pin_probe")

local BOOTSTRAP = fs.join("o", "bootstrap", "cosmic")

local ACCEPTS < const > = "pin-probe: DISCRIMINATES (baseline refuses, " ..
"candidate accepts)"
local REFUSES < const > = "pin-probe: DISCRIMINATES (baseline accepts, " ..
"candidate refuses)"
local BOTH_ACCEPT < const > = "pin-probe: VACUOUS (both accept)"
local BOTH_REFUSE < const > = "pin-probe: VACUOUS (both refuse; a differing " ..
"message is not discrimination)"

--- Write a probe source into this test's temp directory.
--- @param name string The file name
--- @param source string The probe's bytes
--- @return string The path written
local function write_probe(name: string, source: string): string
  local path = fs.join(check.must(os.getenv("TEST_TMPDIR")), name)
  check.must(fs.write(path, source))
  return path
end

--- The bootstrap, or a loud failure naming how to land it — a test
--- that silently skipped would report PASS over nothing.
--- @return string The bootstrap path
local function bootstrap(): string
  assert(fs.is_file(BOOTSTRAP), BOOTSTRAP ..
    " is missing; run bin/cosmic once (any verb) to land it")
  return BOOTSTRAP
end

local function test_verdict_baseline_refuses_candidate_accepts()
  local line, ok = pin_probe.verdict(1, 0)
  check.equal(line, ACCEPTS)
  check.truthy(ok, "opposite statuses discriminate")
end
test_verdict_baseline_refuses_candidate_accepts()

local function test_verdict_baseline_accepts_candidate_refuses()
  local line, ok = pin_probe.verdict(0, 1)
  check.equal(line, REFUSES)
  check.truthy(ok, "opposite statuses discriminate the other way too")
end
test_verdict_baseline_accepts_candidate_refuses()

local function test_verdict_both_accept_is_vacuous()
  local line, ok = pin_probe.verdict(0, 0)
  check.equal(line, BOTH_ACCEPT)
  check.equal(ok, false, "two acceptances prove nothing")
end
test_verdict_both_accept_is_vacuous()

local function test_verdict_both_refuse_is_vacuous()
  local line, ok = pin_probe.verdict(1, 1)
  check.equal(line, BOTH_REFUSE)
  check.equal(ok, false, "two refusals prove nothing, whatever they printed")
end
test_verdict_both_refuse_is_vacuous()

local function test_report_both_accept_end_to_end()
  local probe = write_probe("accept_probe.tl", "local _x: integer = 1\n")
  local text, code = pin_probe.report(probe, bootstrap(), bootstrap())
  check.equal(text:sub(-#BOTH_ACCEPT), BOTH_ACCEPT, text)
  check.equal(code, 1, "a vacuous probe exits 1")
  check.truthy(text:find("baseline: ", 1, true), "the baseline block prints")
  check.truthy(text:find("candidate: ", 1, true), "the candidate block prints")
end
test_report_both_accept_end_to_end()

local function test_report_both_refuse_end_to_end()
  local probe = write_probe("refuse_probe.tl", "local _x: integer = \"s\"\n")
  local text, code = pin_probe.report(probe, bootstrap(), bootstrap())
  check.equal(text:sub(-#BOTH_REFUSE), BOTH_REFUSE, text)
  check.equal(code, 1, "a vacuous probe exits 1")
end
test_report_both_refuse_end_to_end()

local function test_report_refuses_a_missing_probe()
  local text, code = pin_probe.report(
    fs.join(check.must(os.getenv("TEST_TMPDIR")), "nope.tl"),
    BOOTSTRAP, BOOTSTRAP)
  check.equal(code, 2, "an unreadable probe is neither verdict")
  check.truthy(text:find("cannot read probe file", 1, true), text)
end
test_report_refuses_a_missing_probe()

local function test_main_refuses_a_wrong_argument_count()
  check.equal(pin_probe.main("only-one"), 2, "usage errors exit 2")
end
test_main_refuses_a_wrong_argument_count()
