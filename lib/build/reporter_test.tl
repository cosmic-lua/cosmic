#!/usr/bin/env cosmic

local path = require("cosmo.path")
local unix = require("cosmo.unix")
local cosmo = require("cosmo")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function write_test_result(base: string, exit_code: integer, stdout: string, stderr: string)
  local dir = path.dirname(base)
  if dir and dir ~= "" and dir ~= "." then
    unix.makedirs(dir)
  end
  cosmo.Barf(base .. ".got", tostring(exit_code) .. "\n")
  cosmo.Barf(base .. ".out", stdout or "")
  cosmo.Barf(base .. ".err", stderr or "")
end

local record SpawnHandle
  stderr: FILE
  read: function(self: SpawnHandle): boolean, string, integer
end

local function run_reporter(...: string): integer, string, string
  local test_bin = os.getenv("TEST_BIN") or ""
  local test_o = os.getenv("TEST_O") or "o"
  local reporter = path.join(test_o, "lib/build/reporter.lua")
  local spawn = require("cosmic.child").spawn
  local args: {string} = {path.join(test_bin, "cosmic"), "--", reporter}
  local varargs: {string} = {...}
  for _, a in ipairs(varargs) do
    table.insert(args, a)
  end

  local lua_path = os.getenv("LUA_PATH") or ""
  local new_lua_path = "o/lib/?.lua;o/lib/?/init.lua;;" .. lua_path
  unix.setenv("LUA_PATH", new_lua_path)

  local handle = spawn(args) as SpawnHandle
  local stderr_content = handle.stderr and handle.stderr:read() or ""
  local _ok, stdout, exit_code = handle:read()
  return exit_code, stdout or "", stderr_content
end

-- test single checker mode (test)
local function test_single_checker_mode()
  local test_dir = path.join(tmpdir, "single-checker")
  unix.makedirs(test_dir)

  write_test_result(path.join(test_dir, "test1.test"), 0, "all good\n", "")
  write_test_result(path.join(test_dir, "test2.test"), 1, "", "assertion failed\n")

  local code, stdout, stderr = run_reporter(
    "--dir", test_dir,
    path.join(test_dir, "test1.test.got"),
    path.join(test_dir, "test2.test.got")
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
  local test_dir = path.join(tmpdir, "all-pass")
  unix.makedirs(test_dir)

  write_test_result(path.join(test_dir, "test1.test"), 0, "ok\n", "")
  write_test_result(path.join(test_dir, "test2.test"), 0, "ok\n", "")

  local code, stdout, stderr = run_reporter(
    "--dir", test_dir,
    path.join(test_dir, "test1.test.got"),
    path.join(test_dir, "test2.test.got")
  )

  assert(code == 0, "expected exit code 0 for all passing")
  assert(stdout:match("test: 2 checks: 2 passed, 0 failed"), "expected test summary")
  assert(not stdout:match("FAILURES"), "expected no failures section")
end
test_all_passing()

-- test directory stripping
local function test_directory_stripping()
  local test_dir = path.join(tmpdir, "dir-strip")
  unix.makedirs(test_dir)

  write_test_result(path.join(test_dir, "subdir", "file.test"), 0, "ok\n", "")

  local code, stdout, stderr = run_reporter(
    "--dir", test_dir,
    path.join(test_dir, "subdir", "file.test.got")
  )

  assert(code == 0, "expected exit code 0")
  assert(stdout:match("subdir/file"), "expected directory to be stripped")
  assert(not stdout:match(test_dir), "expected tmpdir not in output")
end
test_directory_stripping()

-- test missing --dir flag
local function test_missing_dir_flag()
  local code, stdout, stderr = run_reporter("file.test.got")

  assert(code == 1, "expected exit code 1")
  assert(stderr:match("%-%-dir is required"), "expected error about --dir")
end
test_missing_dir_flag()

-- test no files specified
local function test_no_files()
  local code, stdout, stderr = run_reporter("--dir", tmpdir)

  assert(code == 1, "expected exit code 1")
  assert(stderr:match("usage:"), "expected usage error")
end
test_no_files()

-- test message extraction from stderr on failure
local function test_message_from_stderr()
  local test_dir = path.join(tmpdir, "msg-stderr")
  unix.makedirs(test_dir)

  write_test_result(path.join(test_dir, "fail.test"), 1, "", "first line error\nsecond line\n")

  local code, stdout, stderr = run_reporter(
    "--dir", test_dir,
    path.join(test_dir, "fail.test.got")
  )

  assert(code == 1, "expected exit code 1")
  assert(stdout:match("first line error"), "expected first line of stderr as message")
end
test_message_from_stderr()

