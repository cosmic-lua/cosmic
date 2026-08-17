local fs = require("cosmic.fs")
local check = require("cosmic.check")
local net = require("cosmic.net")
local time = require("cosmic.time")
local support = require("_eval.checks.support")
local child_tcp = require("_eval.checks.child-tcp")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Every task's check function, keyed by task id -- the same registry
--- score.tl scores real runs with, so this file can drive each check
--- directly (without going through a full score.main() run) against
--- the identical list.
local CHECKS < const > = require("_eval.checks.registry").CHECKS

local TASKS < const >: {string} = {
  "json-cli", "module-tests", "sqlite-indexer", "child-tcp",
  "text-report", "multi-module-build", "contained-task",
}

--- Copy one committed fixture workspace into a scratch directory. Every
--- check pins its own testdata inputs into the workspace it is given
--- (and the contained-task check creates o/out, o/denied), so no check
--- may ever run directly against the committed _eval/testdata tree.
--- @param run string The fixture run dir's name (e.g. "run_pass")
--- @param task string The task id (workspace directory name)
--- @return string The scratch copy's path
local function copy_workspace(run: string, task: string): string
  local src = fs.join("_eval/testdata", run, task)
  local dst = fs.join(tmpdir, "checks-" .. run .. "-" .. task .. "-" ..
    tostring(os.time()) .. "-" .. tostring(math.random(1000000)))
  check.must(fs.copy_tree(src, dst))
  return dst
end

local function test_every_check_passes_its_own_run_pass_workspace()
  for _, task in ipairs(TASKS) do
    local ws = copy_workspace("run_pass", task)
    local count, findings = CHECKS[task](ws)
    assert(count == 0, task .. ": expected 0 findings on run_pass, got " ..
      count .. ": " .. table.concat(findings, "; "))
  end
end
test_every_check_passes_its_own_run_pass_workspace()

local function test_json_cli_check_catches_the_seeded_defect()
  local ws = copy_workspace("run_fail", "json-cli")
  local count, findings = CHECKS["json-cli"](ws)
  assert(count >= 1, "expected the seeded S-trap defect to be caught")
  local found = false
  for _, f in ipairs(findings) do
    if f:find("filter veg", 1, true) then
      found = true
    end
  end
  assert(found, "expected a finding naming the veg filter, got: " ..
    table.concat(findings, "; "))
end
test_json_cli_check_catches_the_seeded_defect()

local function test_support_accumulator_records_findings_in_order()
  local acc = support.new()
  local count, findings = support.result(acc)
  assert(count == 0 and #findings == 0, "a fresh accumulator should have no findings")
  support.fail(acc, "first problem")
  support.fail(acc, "second problem")
  count, findings = support.result(acc)
  assert(count == 2, "expected 2 findings, got " .. count)
  assert(findings[1] == "first problem" and findings[2] == "second problem",
    "fail() should record findings verbatim, in order")
end
test_support_accumulator_records_findings_in_order()

local function test_expect_test_file_present_catches_absence()
  local dir = fs.join(tmpdir, "checks-no-test-file-" ..
    tostring(os.time()) .. "-" .. tostring(math.random(1000000)))
  check.must(fs.make_dirs(dir))
  local acc = support.new()
  support.expect_test_file_present(acc, dir)
  local count = support.result(acc)
  assert(count == 1, "a workspace with no *_test.tl should record one finding")
end
test_expect_test_file_present_catches_absence()

--- The retry-then-give-up path of child-tcp's dial_with_retry never
--- runs against the run_pass fixture above (its serve mode is ready on
--- the first attempt by construction), so it needs its own coverage: a
--- port nothing is listening on, with a tiny budget so the test stays
--- fast, confirming both the nil result and that the loop actually
--- spent its budget retrying rather than giving up on the first
--- ECONNREFUSED.
local function test_dial_with_retry_gives_up_after_its_budget_on_a_closed_port()
  local probe = check.must(net.listen_tcp("127.0.0.1", 0))
  local port = check.must(probe:local_endpoint()).port
  check.must(probe:close())

  local start = time.monotonic_ms()
  local sock, err = child_tcp.dial_with_retry(port, 80, 20)
  local elapsed = time.monotonic_ms() - start
  assert(sock == nil, "expected no connection to a port nothing listens on")
  assert(err ~= nil and #err > 0, "expected a non-empty dial error")
  assert(elapsed >= 80, "expected the retry loop to spend its full budget, took " ..
    tostring(elapsed) .. "ms")
end
test_dial_with_retry_gives_up_after_its_budget_on_a_closed_port()

local function test_expect_source_contains_catches_absence()
  local dir = fs.join(tmpdir, "checks-no-source-match-" ..
    tostring(os.time()) .. "-" .. tostring(math.random(1000000)))
  check.must(fs.make_dirs(dir))
  check.must(fs.write(fs.join(dir, "main.tl"), "print('hello')\n"))
  local acc = support.new()
  support.expect_source_contains(acc, dir, 'require("cosmic.sandbox")')
  local count = support.result(acc)
  assert(count == 1, "a workspace with no matching source should record one finding")
end
test_expect_source_contains_catches_absence()
