#!/usr/bin/env cosmic

local env = require("cosmic.env")
local fs = require("cosmic.fs")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function write_test_result(base: string, exit_code: integer, stdout: string, stderr: string)
  local dir = fs.dirname(base)
  if dir and dir ~= "" and dir ~= "." then
    fs.makedirs(dir)
  end
  fs.write(base .. ".got", tostring(exit_code) .. "\n")
  fs.write(base .. ".out", stdout or "")
  fs.write(base .. ".err", stderr or "")
end

local function run_reporter(...: string): integer, string, string
  local test_bin = os.getenv("TEST_BIN") or ""
  local test_o = os.getenv("TEST_O") or "o"
  local reporter = fs.join(test_o, "_build/reporter.lua")
  local child = require("cosmic.child")
  local args: {string} = {fs.join(test_bin, "cosmic"), "--", reporter}
  local varargs: {string} = {...}
  for _, a in ipairs(varargs) do
    table.insert(args, a)
  end

  local lua_path = os.getenv("LUA_PATH") or ""
  local new_lua_path = "o/lib/?.lua;o/lib/?/init.lua;;" .. lua_path
  env.set("LUA_PATH", new_lua_path)

  local result, serr = child.run(args)
  if not result then
    return 1, "", tostring(serr)
  end
  local r = result as child.Result -- cast: record union after guard
  local exit_code: integer = 1
  if r.code ~= nil then
    exit_code = r.code
  elseif r.signal ~= nil then
    exit_code = (128 + r.signal)
  end
  return exit_code, r.stdout, r.stderr
end

-- test single checker mode (test)
local function test_single_checker_mode()
  local test_dir = fs.join(tmpdir, "single-checker")
  fs.makedirs(test_dir)

  write_test_result(fs.join(test_dir, "test1.test"), 0, "all good\n", "")
  write_test_result(fs.join(test_dir, "test2.test"), 1, "", "assertion failed\n")

  local code, stdout, _stderr = run_reporter(
    "--dir", test_dir,
    fs.join(test_dir, "test1.test.got"),
    fs.join(test_dir, "test2.test.got")
  )

  assert(code == 1, "expected exit code 1 for failures, got: " .. tostring(code))
  assert(stdout:match("PASS"), "expected PASS in output")
  assert(stdout:match("FAIL"), "expected FAIL in output")
  assert(stdout:match("test: 2 checks: 1 passed, 1 failed"), "expected test summary")
  assert(stdout:match("FAILURES"), "expected failures section")
end
test_single_checker_mode()

-- test all passing
local function test_all_passing()
  local test_dir = fs.join(tmpdir, "all-pass")
  fs.makedirs(test_dir)

  write_test_result(fs.join(test_dir, "test1.test"), 0, "ok\n", "")
  write_test_result(fs.join(test_dir, "test2.test"), 0, "ok\n", "")

  local code, stdout, _stderr = run_reporter(
    "--dir", test_dir,
    fs.join(test_dir, "test1.test.got"),
    fs.join(test_dir, "test2.test.got")
  )

  assert(code == 0, "expected exit code 0 for all passing")
  assert(stdout:match("test: 2 checks: 2 passed, 0 failed"), "expected test summary")
  assert(not stdout:match("FAILURES"), "expected no failures section")
end
test_all_passing()

-- test directory stripping
local function test_directory_stripping()
  local test_dir = fs.join(tmpdir, "dir-strip")
  fs.makedirs(test_dir)

  write_test_result(fs.join(test_dir, "subdir", "file.test"), 0, "ok\n", "")

  local code, stdout, _stderr = run_reporter(
    "--dir", test_dir,
    fs.join(test_dir, "subdir", "file.test.got")
  )

  assert(code == 0, "expected exit code 0")
  assert(stdout:match("subdir/file"), "expected directory to be stripped")
  assert(not stdout:match(test_dir), "expected tmpdir not in output")
end
test_directory_stripping()

-- test missing --dir flag
local function test_missing_dir_flag()
  local code, _stdout, stderr = run_reporter("file.test.got")

  assert(code == 1, "expected exit code 1")
  assert(stderr:match("%-%-dir is required"), "expected error about --dir")
end
test_missing_dir_flag()

-- test no files specified
local function test_no_files()
  local code, _stdout, stderr = run_reporter("--dir", tmpdir)

  assert(code == 1, "expected exit code 1")
  assert(stderr:match("usage:"), "expected usage error")
end
test_no_files()

-- test message extraction from stderr on failure
local function test_message_from_stderr()
  local test_dir = fs.join(tmpdir, "msg-stderr")
  fs.makedirs(test_dir)

  write_test_result(fs.join(test_dir, "fail.test"), 1, "", "first line error\nsecond line\n")

  local code, stdout, _stderr = run_reporter(
    "--dir", test_dir,
    fs.join(test_dir, "fail.test.got")
  )

  assert(code == 1, "expected exit code 1")
  assert(stdout:match("first line error"), "expected first line of stderr as message")
end
test_message_from_stderr()

-- --out writes the same report the recipes used to `| tee`
local function test_out_writes_file()
  local test_dir = fs.join(tmpdir, "out-file")
  fs.makedirs(test_dir)

  write_test_result(fs.join(test_dir, "a.test"), 0, "ok\n", "")
  local out_path = fs.join(test_dir, "summary.txt")

  local code, stdout, _stderr = run_reporter(
    "--dir", test_dir, "--out", out_path,
    fs.join(test_dir, "a.test.got")
  )

  assert(code == 0, "expected exit code 0, got: " .. tostring(code))
  local written = fs.read(out_path)
  assert(written == stdout, "summary file must match stdout, got: " .. tostring(written))
end
test_out_writes_file()

-- REPORTER_NOTE appends a line to report and file: note text carries
-- spaces, which a shell-free recipe argv cannot pass as a flag
local function test_reporter_note()
  local test_dir = fs.join(tmpdir, "note")
  fs.makedirs(test_dir)

  write_test_result(fs.join(test_dir, "a.test"), 0, "ok\n", "")
  local out_path = fs.join(test_dir, "summary.txt")
  env.set("REPORTER_NOTE", "lint: skipped deleted tracked file(s): gone.tl")

  local code, stdout, _stderr = run_reporter(
    "--dir", test_dir, "--out", out_path,
    fs.join(test_dir, "a.test.got")
  )
  env.unset("REPORTER_NOTE")

  assert(code == 0, "expected exit code 0, got: " .. tostring(code))
  assert(stdout:match("skipped deleted tracked file%(s%): gone%.tl"),
    "expected note in stdout, got: " .. stdout)
  -- cast: or fallback does not narrow
  local written = (fs.read(out_path) or "") as string
  assert(written:match("gone%.tl"), "expected note in summary file")
end
test_reporter_note()

-- The ci verdict (_cli.build's do_verdict) grades a stage by matching
-- this pattern against whatever summary the stage produced — and the build
-- has TWO producers: this reporter, for the teal/format/lint/example/
-- benchmark stages, and `cosmic --report` (cosmic.testrun) for the
-- test/coverage/enforce lanes. They format differently ON PURPOSE (the
-- reporter always prints "0 failed"; testrun omits the clause at zero), so
-- the shared contract is narrow but load-bearing: a summary WITH failures
-- must carry a matching clause, one WITHOUT must not. Pin it for both, or
-- a format tweak on either side silently makes ci grade a red stage green
-- — the laundering class, one layer up.
local VERDICT_PATTERN < const > = "[1-9]%d* failed"

local function run_report(...: string): integer, string
  local child = require("cosmic.child")
  local args: {string} = {fs.join(os.getenv("TEST_BIN") or "", "cosmic"), "--report"}
  for _, a in ipairs({...}) do
    table.insert(args, a)
  end
  local result, serr = child.run(args)
  assert(result, "spawn cosmic --report failed: " .. tostring(serr))
  local r = result as child.Result -- cast: record union after guard
  return (r.code or 1), r.stdout
end

local function test_verdict_pattern_agrees_across_both_reporters()
  local dir = fs.join(tmpdir, "verdict")
  fs.makedirs(dir)
  write_test_result(fs.join(dir, "red.test"), 1, "", "boom\n")
  write_test_result(fs.join(dir, "green.test"), 0, "ok\n", "")

  -- _build/reporter: the check stages
  local rc, rout = run_reporter("--dir", dir, fs.join(dir, "red.test.got"))
  assert(rc ~= 0, "reporter must exit nonzero on a failure")
  assert(rout:match(VERDICT_PATTERN),
    "reporter failure summary must carry the clause ci grades on:\n" .. rout)
  local _, rpass = run_reporter("--dir", dir, fs.join(dir, "green.test.got"))
  assert(not rpass:match(VERDICT_PATTERN),
    "reporter all-pass summary must NOT match the failure clause:\n" .. rpass)

  -- cosmic --report (cosmic.testrun): the test lanes
  local tc, tout = run_report(fs.join(dir, "red.test.got"))
  assert(tc ~= 0, "cosmic --report must exit nonzero on a failure")
  assert(tout:match(VERDICT_PATTERN),
    "testrun failure summary must carry the clause ci grades on:\n" .. tout)
  local _, tpass = run_report(fs.join(dir, "green.test.got"))
  assert(not tpass:match(VERDICT_PATTERN),
    "testrun all-pass summary must NOT match the failure clause:\n" .. tpass)
end
test_verdict_pattern_agrees_across_both_reporters()

-- test: both reporters read the exit-code contract from one place
local function test_status_contract_is_shared()
  local testrun = require("cosmic.testrun")
  assert(testrun.status_of(0) == "pass", "0 is a pass")
  assert(testrun.status_of(2) == "skip", "2 is a skip")
  assert(testrun.status_of(1) == "fail", "1 is a failure")
  assert(testrun.status_of(127) == "fail", "127 is a failure")

  -- and the reporter classifies through it: a .got of 2 reports as a skip
  local dir = fs.join(tmpdir, "skipstatus")
  fs.makedirs(dir)
  write_test_result(fs.join(dir, "s.test"), 2, "", "")
  local code, out = run_reporter("--dir", dir, fs.join(dir, "s.test.got"))
  assert(code == 0, "a skip must not fail the stage, got: " .. tostring(code))
  assert(out:match("1 skipped"), "reporter should count exit 2 as a skip:\n" .. out)
end
test_status_contract_is_shared()
