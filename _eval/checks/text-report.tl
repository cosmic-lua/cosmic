--- Functional check for the text-report task
--- (_eval/tasks/text-report.md): exercises the built `o/bin/logreport`
--- against a pinned copy of the brief's fixture log, asserting exact
--- bucketed output -- including the two boundary S-traps (an
--- on-the-hour timestamp belongs to the bucket it starts, not the one
--- before it).
local support = require("_eval.checks.support")

local BIN < const > = "o/bin/logreport"

local EVENTS_LOG < const > = table.concat({
    "2026-08-01T10:15:00Z INFO start",
    "2026-08-01T10:59:59Z WARN low-disk",
    "2026-08-01T11:00:00Z INFO tick",
    "2026-08-01T11:30:12Z ERROR crash",
    "2026-08-01T12:00:00Z INFO tick",
    "2026-08-01T12:00:01Z INFO tick",
    "2026-08-01T13:59:59Z WARN slow",
  }, "\n") .. "\n"

local WANT_REPORT < const > = table.concat({
    "2026-08-01T10:00Z 2",
    "2026-08-01T11:00Z 2",
    "2026-08-01T12:00Z 2",
    "2026-08-01T13:00Z 1",
    "total 7",
  }, "\n") .. "\n"

--- @param workspace string Absolute path to the task's workspace
--- @return integer The number of failed Acceptance facts
--- @return {string} What failed, one entry per count
local function check(workspace: string): integer, {string}
  local acc = support.new()

  local wok, werr = support.write_fixture(workspace, "testdata/events.log", EVENTS_LOG)
  if not wok then
    support.fail(acc, "could not write fixture testdata/events.log: " .. tostring(werr))
    return support.result(acc)
  end
  local eok, eerr = support.write_fixture(workspace, "empty.log", "")
  if not eok then
    support.fail(acc, "could not write fixture empty.log: " .. tostring(eerr))
    return support.result(acc)
  end

  -- S-trap: the on-the-hour boundary must fall in the bucket it
  -- starts, both approaching (11:00:00) and leaving (12:00:01) it.
  local res, err = support.run(workspace, BIN, {"testdata/events.log"})
  if support.expect_exit(acc, "logreport events.log", res, err, true) then
    support.expect_stdout(acc, "logreport events.log", res, WANT_REPORT)
  end

  res, err = support.run(workspace, BIN, {"empty.log"})
  if support.expect_exit(acc, "logreport empty.log", res, err, true) then
    support.expect_stdout(acc, "logreport empty.log", res, "total 0\n")
  end

  res, err = support.run(workspace, BIN, {"testdata/absent.log"})
  if support.expect_exit(acc, "logreport absent.log", res, err, false) then
    support.expect_empty_stdout(acc, "logreport absent.log", res)
    support.expect_nonempty_stderr(acc, "logreport absent.log", res)
  end

  support.expect_test_file_present(acc, workspace)
  -- The brief's fact is a TEST covering the on-the-hour boundary, not
  -- merely a test file's presence -- assert the literal that proves it.
  support.expect_source_contains(acc, workspace, "11:00:00")

  return support.result(acc)
end

local record text_report_check
  check: function(workspace: string): integer, {string}
end

local M: text_report_check = {
  check = check,
}

return M
