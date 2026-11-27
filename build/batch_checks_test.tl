local batch_checks = require("build.batch_checks")

local function check(name: string, status: string, conclusion: string?, started_at: string): batch_checks.CheckRun
  return { name = name, status = status, conclusion = conclusion, started_at = started_at }
end

local function said(runs: {batch_checks.CheckRun}): string
  return batch_checks.refusal(runs) or "nil"
end

--- A ready pull request whose run passed every job, macOS's suite among
--- them, is let in; a skipped matrix job does not hold it out.
local function test_a_ready_run_that_passed_every_job_is_let_in()
  local runs = {
    check("linux-x86_64", "completed", "success", "2026-11-26T21:48:30Z"),
    check("macos-aarch64", "completed", "success", "2026-11-26T21:48:30Z"),
    check("matrix.name", "completed", "skipped", "2026-11-26T21:48:30Z"),
    check("ci", "completed", "success", "2026-11-26T22:08:50Z"),
  }
  assert(batch_checks.refusal(runs) == nil, said(runs))
end

--- Batch 77's case: the draft run's `ci` gate passed, and the ready run's
--- macOS suite, which has no gate yet, is still running. The pull
--- request waits.
local function test_a_running_macos_suite_holds_it_though_an_older_gate_passed()
  local runs = {
    check("linux-x86_64", "completed", "success", "2026-11-26T21:36:55Z"),
    check("ci", "completed", "success", "2026-11-26T21:45:00Z"),
    check("linux-x86_64", "completed", "success", "2026-11-26T21:48:30Z"),
    check("macos-aarch64", "in_progress", nil, "2026-11-26T21:48:30Z"),
  }
  assert(said(runs) == "its checks are still running: macos-aarch64", said(runs))
end

--- Once that macOS suite fails, the pull request is held out, though the
--- draft run's gate passed.
local function test_a_failed_macos_suite_holds_it_out()
  local runs = {
    check("ci", "completed", "success", "2026-11-26T21:45:00Z"),
    check("macos-aarch64", "completed", "failure", "2026-11-26T21:48:30Z"),
    check("ci", "completed", "failure", "2026-11-26T22:08:50Z"),
  }
  assert(said(runs) == "its newest macos-aarch64 check is failure", said(runs))
end

--- A draft's run has no macOS suite, so its green does not let it in.
local function test_a_draft_run_with_no_macos_suite_holds_it_out()
  local runs = {
    check("linux-x86_64", "completed", "success", "2026-11-26T21:36:55Z"),
    check("linux-x86_64-driver", "completed", "success", "2026-11-26T21:36:55Z"),
    check("ci", "completed", "success", "2026-11-26T21:45:00Z"),
  }
  assert(said(runs):match("^no passed macos%-aarch64 check at its head: mark it ready") ~= nil, said(runs))
end

--- The newest run of a name decides: a job that failed and then passed
--- on a re-run lets the pull request in.
local function test_a_rerun_that_passed_takes_the_failed_runs_place()
  local runs = {
    check("macos-aarch64", "completed", "failure", "2026-11-26T21:48:30Z"),
    check("ci", "completed", "failure", "2026-11-26T22:08:50Z"),
    check("macos-aarch64", "completed", "success", "2026-11-26T22:30:00Z"),
    check("ci", "completed", "success", "2026-11-26T22:45:00Z"),
  }
  assert(batch_checks.refusal(runs) == nil, said(runs))
end

--- With no `ci` check at all the head has not been tested.
local function test_no_ci_check_holds_it_out()
  assert(said({}) == "no ci check at its head", said({}))
end
