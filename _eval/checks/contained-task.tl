--- Functional check for the contained-task task
--- (_eval/tasks/contained-task.md): exercises the built `o/bin/copybox`
--- in its three modes -- caps, denied (--deny-write), and granted --
--- asserting the exact denial-then-grant behavior a fail-closed
--- filesystem sandbox must produce. Runs the denied mode before the
--- granted one, matching the brief's own ordering requirement (sandbox
--- application is irreversible and process-wide, so the two must be
--- separate processes -- which support.run already guarantees, one
--- child per call).
local fs = require("cosmic.fs")
local support = require("_eval.checks.support")

local BIN < const > = "o/bin/copybox"
local IN_TXT < const > = "hello\n"

--- @param workspace string Absolute path to the task's workspace
--- @return integer The number of failed Acceptance facts
--- @return {string} What failed, one entry per count
local function check(workspace: string): integer, {string}
  local acc = support.new()

  local wok, werr = support.write_fixture(workspace, "testdata/in.txt", IN_TXT)
  if not wok then
    support.fail(acc, "could not write fixture testdata/in.txt: " .. tostring(werr))
    return support.result(acc)
  end
  local mok, merr = fs.make_dirs(fs.join(workspace, "o/denied"))
  if not mok then
    support.fail(acc, "could not create o/denied: " .. tostring(merr))
    return support.result(acc)
  end
  mok, merr = fs.make_dirs(fs.join(workspace, "o/out"))
  if not mok then
    support.fail(acc, "could not create o/out: " .. tostring(merr))
    return support.result(acc)
  end

  support.expect_source_contains(acc, workspace, 'require("cosmic.sandbox")')
  support.expect_source_contains(acc, workspace, ".apply(")

  local res, err = support.run(workspace, BIN, {"caps"})
  if support.expect_exit(acc, "copybox caps", res, err, true) then
    support.expect_stdout(acc, "copybox caps", res, "fs=true\n")
  end

  -- Denied mode first: the denial must be enforced, not simulated --
  -- the destination file must not exist afterward.
  res, err = support.run(workspace, BIN, {"--deny-write", "testdata/in.txt", "o/denied"})
  if support.expect_exit(acc, "copybox --deny-write", res, err, false) then
    support.expect_stdout_starts_with(acc, "copybox --deny-write", res,
      "denied: write to o/denied")
    support.expect_stdout_contains(acc, "copybox --deny-write", res, "fs.rw")
  end
  if fs.is_present(fs.join(workspace, "o/denied/in.txt")) then
    support.fail(acc, "copybox --deny-write: o/denied/in.txt exists; the denial " ..
      "was not actually enforced")
  end

  -- Granted mode, in a separate process (application is irreversible).
  res, err = support.run(workspace, BIN, {"testdata/in.txt", "o/out"})
  if support.expect_exit(acc, "copybox testdata/in.txt o/out", res, err, true) then
    support.expect_stdout(acc, "copybox testdata/in.txt o/out", res, "copied 6 bytes\n")
  end
  local copied = fs.read(fs.join(workspace, "o/out/in.txt"))
  if copied ~= IN_TXT then
    support.fail(acc, "o/out/in.txt is not byte-identical to testdata/in.txt")
  end

  res, err = support.run(workspace, BIN, {"testdata/absent.txt", "o/out"})
  if support.expect_exit(acc, "copybox absent source", res, err, false) then
    support.expect_empty_stdout(acc, "copybox absent source", res)
    support.expect_nonempty_stderr(acc, "copybox absent source", res)
  end

  support.expect_test_file_present(acc, workspace)
  -- The brief's fact is a TEST that spawns copybox in both denied and
  -- granted modes, not merely a test file's presence -- assert the
  -- literal invocations that prove it.
  support.expect_source_contains(acc, workspace, "--deny-write")
  support.expect_source_contains(acc, workspace, "o/out")

  return support.result(acc)
end

local record contained_task_check
  check: function(workspace: string): integer, {string}
end

local M: contained_task_check = {
  check = check,
}

return M
