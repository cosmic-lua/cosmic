--- Shared plumbing for the seven per-task check modules
--- (_eval/checks/<id>.tl): an assertion accumulator that turns a
--- series of pass/fail facts into the (count, findings) tuple every
--- check returns, a workspace-relative binary runner, and the one
--- fact common to every brief (a *_test.tl file exists) so it is
--- implemented once instead of seven times.
---
--- Deliberately NOT in scope here: re-running `<workspace>/cosmic
--- --make ci` to reverify the "ci: PASS" acceptance fact. Doing that
--- meaningfully needs the real candidate binary and a real Teal
--- project tree; this instrument's own fixture run dirs are
--- deliberately binary-free (_eval/testdata/**), and re-running the
--- full gate is exactly what G4's gate_adopted metric already covers
--- -- journal-derived and nullable in v1 (see eval_types.Row). A
--- check module here scores the artifact's BEHAVIOR against the
--- brief's S-trap and shape facts; it never re-derives "did the gate
--- go green", the same way it never reads NOTES.md.
local child = require("cosmic.child")
local fs = require("cosmic.fs")

--- Accumulates findings across a check's assertions. Never exported --
--- callers only see the (integer, {string}) tuple result() returns.
local record Acc
  findings: {string}
end

--- A fresh, empty accumulator.
--- @return Acc
local function new(): Acc
  return {findings = {}}
end

--- Record one failed assertion.
--- @param acc Acc The accumulator
--- @param msg string What failed, specific enough to act on
local function fail(acc: Acc, msg: string)
  acc.findings[#acc.findings + 1] = msg
end

--- The check() return shape: findings count, and the findings
--- themselves (count == #findings, per the check contract).
--- @param acc Acc The accumulator
--- @return integer The number of failed assertions
--- @return {string} The findings, in the order recorded
local function result(acc: Acc): integer, {string}
  return #acc.findings, acc.findings
end

--- Run a workspace-relative binary, cwd'd into the workspace, exactly
--- as the brief's Acceptance facts invoke it (`./o/bin/<name> ...`).
--- @param workspace string Absolute path to the task's workspace
--- @param bin_rel string Binary path relative to the workspace, e.g. "o/bin/jstat"
--- @param args {string} Arguments after the binary
--- @return child.Result|nil The finished process, or nil if it could not run
--- @return string Error message on failure
local function run(workspace: string, bin_rel: string, args: {string}):
  child.Result | nil, string
  local argv: {string} = {fs.join(workspace, bin_rel)}
  for _, a in ipairs(args) do
    argv[#argv + 1] = a
  end
  return child.run(argv, {cwd = workspace})
end

--- Assert a run's exit code and record a finding on mismatch. Always
--- returns whether the run itself even produced a Result, so callers
--- can skip inspecting stdout/stderr on a run that never happened.
--- @param acc Acc The accumulator
--- @param label string What this assertion is checking, for the message
--- @param res child.Result|nil The run's result
--- @param err string The run's error, when res is nil
--- @param want_zero boolean True to require exit 0, false to require non-zero
--- @return boolean True when res is non-nil (a process actually ran)
local function expect_exit(acc: Acc, label: string, res: child.Result | nil,
    err: string, want_zero: boolean): boolean
  if res == nil then
    fail(acc, label .. ": failed to run: " .. tostring(err))
    return false
  end
  local zero = res.code == 0
  if want_zero and not zero then
    fail(acc, label .. ": expected exit 0, got " .. tostring(res.code) ..
      " (stderr: " .. res.stderr .. ")")
  elseif not want_zero and zero then
    fail(acc, label .. ": expected a non-zero exit, got 0")
  end
  return true
end

--- Assert stdout equals `want` exactly.
--- @param acc Acc The accumulator
--- @param label string What this assertion is checking
--- @param res child.Result The run's result
--- @param want string The exact expected stdout
local function expect_stdout(acc: Acc, label: string, res: child.Result, want: string)
  if res.stdout ~= want then
    fail(acc, label .. ": stdout mismatch: want " .. string.format("%q", want) ..
      " got " .. string.format("%q", res.stdout))
  end
end

--- Assert stdout is empty.
--- @param acc Acc The accumulator
--- @param label string What this assertion is checking
--- @param res child.Result The run's result
local function expect_empty_stdout(acc: Acc, label: string, res: child.Result)
  if res.stdout ~= "" then
    fail(acc, label .. ": expected empty stdout, got " ..
      string.format("%q", res.stdout))
  end
end

--- Assert stderr is non-empty.
--- @param acc Acc The accumulator
--- @param label string What this assertion is checking
--- @param res child.Result The run's result
local function expect_nonempty_stderr(acc: Acc, label: string, res: child.Result)
  if res.stderr == "" then
    fail(acc, label .. ": expected a non-empty stderr message, got none")
  end
end

--- Assert stderr contains a substring (plain text, not a pattern).
--- @param acc Acc The accumulator
--- @param label string What this assertion is checking
--- @param res child.Result The run's result
--- @param want string The substring stderr must contain
local function expect_stderr_contains(acc: Acc, label: string, res: child.Result,
    want: string)
  if not res.stderr:find(want, 1, true) then
    fail(acc, label .. ": expected stderr to contain " .. string.format("%q", want) ..
      ", got " .. string.format("%q", res.stderr))
  end
end

--- Assert stdout starts with a prefix (plain text, not a pattern).
--- @param acc Acc The accumulator
--- @param label string What this assertion is checking
--- @param res child.Result The run's result
--- @param want string The prefix stdout must start with
local function expect_stdout_starts_with(acc: Acc, label: string, res: child.Result,
    want: string)
  if res.stdout:sub(1, #want) ~= want then
    fail(acc, label .. ": expected stdout to start with " .. string.format("%q", want) ..
      ", got " .. string.format("%q", res.stdout))
  end
end

--- Assert stdout contains a substring (plain text, not a pattern).
--- @param acc Acc The accumulator
--- @param label string What this assertion is checking
--- @param res child.Result The run's result
--- @param want string The substring stdout must contain
local function expect_stdout_contains(acc: Acc, label: string, res: child.Result,
    want: string)
  if not res.stdout:find(want, 1, true) then
    fail(acc, label .. ": expected stdout to contain " .. string.format("%q", want) ..
      ", got " .. string.format("%q", res.stdout))
  end
end

--- The one fact every brief shares: the workspace contains at least
--- one `*_test.tl` file. Cheap and binary-free, so it is asserted the
--- same way for all seven tasks rather than reimplemented per check.
--- @param acc Acc The accumulator
--- @param workspace string Absolute path to the task's workspace
local function expect_test_file_present(acc: Acc, workspace: string)
  local found = fs.find(workspace, {glob = "*_test.tl", recursive = true})
  if found == nil or #found == 0 then
    fail(acc, "workspace has no *_test.tl file")
  end
end

--- Assert some `*.tl` file in the workspace contains a substring
--- (plain text). For facts phrased "<file> (or a module it requires)
--- contains X" -- scanning every source file is simpler and more
--- honest than assuming which one the agent put it in.
--- @param acc Acc The accumulator
--- @param workspace string Absolute path to the task's workspace
--- @param want string The substring some *.tl file must contain
local function expect_source_contains(acc: Acc, workspace: string, want: string)
  local found = fs.find(workspace, {glob = "*.tl", recursive = true})
  if found then
    for _, path in ipairs(found) do
      local src = fs.read(path)
      if src and src:find(want, 1, true) then
        return
      end
    end
  end
  fail(acc, "no *.tl file in the workspace contains " .. string.format("%q", want))
end

--- Write a fixture file, creating its parent directory first. Every
--- check pins its own inputs (never trusting the agent's fixture
--- bytes) by writing them here before invoking the binary.
--- @param workspace string Absolute path to the task's workspace
--- @param rel string Path relative to the workspace
--- @param data string The exact bytes to write
--- @return boolean True on success
--- @return string Error message on failure
local function write_fixture(workspace: string, rel: string, data: string):
  boolean, string
  local path = fs.join(workspace, rel)
  local dir = fs.dirname(path)
  if dir ~= "" and dir ~= "." then
    local ok, err = fs.make_dirs(dir)
    if not ok then
      return false, "make " .. dir .. ": " .. tostring(err)
    end
  end
  return fs.write(path, data)
end

local record support_module
  type Acc = Acc
  new: function(): Acc
  fail: function(acc: Acc, msg: string)
  result: function(acc: Acc): integer, {string}
  run: function(workspace: string, bin_rel: string, args: {string}):
  child.Result | nil, string
  expect_exit: function(acc: Acc, label: string, res: child.Result | nil,
  err: string, want_zero: boolean): boolean
  expect_stdout: function(acc: Acc, label: string, res: child.Result, want: string)
  expect_empty_stdout: function(acc: Acc, label: string, res: child.Result)
  expect_nonempty_stderr: function(acc: Acc, label: string, res: child.Result)
  expect_stderr_contains: function(acc: Acc, label: string, res: child.Result,
  want: string)
  expect_stdout_starts_with: function(acc: Acc, label: string, res: child.Result,
  want: string)
  expect_stdout_contains: function(acc: Acc, label: string, res: child.Result,
  want: string)
  expect_test_file_present: function(acc: Acc, workspace: string)
  expect_source_contains: function(acc: Acc, workspace: string, want: string)
  write_fixture: function(workspace: string, rel: string, data: string):
  boolean, string
end

local M: support_module = {
  new = new,
  fail = fail,
  result = result,
  run = run,
  expect_exit = expect_exit,
  expect_stdout = expect_stdout,
  expect_empty_stdout = expect_empty_stdout,
  expect_nonempty_stderr = expect_nonempty_stderr,
  expect_stderr_contains = expect_stderr_contains,
  expect_stdout_starts_with = expect_stdout_starts_with,
  expect_stdout_contains = expect_stdout_contains,
  expect_test_file_present = expect_test_file_present,
  expect_source_contains = expect_source_contains,
  write_fixture = write_fixture,
}

return M
