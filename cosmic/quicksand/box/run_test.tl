#!/usr/bin/env cosmic
--- Integration test for cosmic.quicksand.Box:run.
---
--- box:run unshares CLONE_NEWUSER, which is irreversible for the
--- calling thread, so every workload runs in a fresh cosmic subprocess.
--- capabilities().user_ns is a real scratch-child unshare probe now, so
--- when the guard passes, setup is expected to succeed: setup failures
--- surface as nil + error over Box:run's error pipe and are hard test
--- failures, not skips. The only tolerated skips are named, specific
--- conditions (an outer seccomp filter SIGSYS-ing the subprocess, or a
--- uid_map write that needs privileges this test does not have).
local quicksand = require("cosmic.quicksand")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local check = require("cosmic.check")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Run `script` in a fresh cosmic subprocess. Returns the Result, or nil
-- after registering a strict skip when the subprocess was killed by a
-- signal (an outer seccomp filter SIGSYS-ing a namespace syscall).
local function run_script(name: string, body: string): spawn.Result
  local script = fs.join(tmpdir, name)
  fs.write(script, body)
  local h = check.must(spawn.spawn({cosmic, script}))
  local r = check.must(h:wait())
  if r.signal ~= nil then
    check.skip("box subprocess killed by signal " .. tostring(r.signal)
      .. " (outer sandbox)", true)
    return nil
  end
  return r
end

local function test_run_true_in_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then
    check.skip("box namespaces unavailable on this host")
    return
  end

  -- user_ns probed true above, so setup must succeed: a nil + error
  -- return or a non-zero exit from /bin/true is a real failure.
  local r = run_script("box_run_true.lua", [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.Box.new({})
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/true"})
if code == nil then
  io.stderr:write("run nil: " .. tostring(rerr) .. "\n"); os.exit(1)
end
if code ~= 0 then
  io.stderr:write("run exit=" .. tostring(code) .. "\n"); os.exit(1)
end
io.write("ok exit=0\n")
]])
  if not r then return end
  assert(r.ok, "box run of /bin/true must succeed: "
    .. tostring(r.stdout) .. tostring(r.stderr))
  assert(r.stdout:find("ok exit=0"),
    "expected ok, got: " .. tostring(r.stdout))
end
test_run_true_in_subprocess()

-- Regression: run() used to call unix.wait(pid) without retrying
-- EINTR, feeding the errno STRING to WIFEXITED on interrupt (a
-- type-error throw instead of a clean result). A one-shot SIGALRM
-- fires ~50ms into a workload that sleeps 300ms, guaranteeing wait(pid)
-- is interrupted mid-block; run() must still return the workload's
-- real exit code.
local function test_run_survives_eintr_during_wait()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then
    check.skip("box namespaces unavailable on this host")
    return
  end

  local r = run_script("box_run_eintr.lua", [[
local signal = require("cosmic.signal")
local qs = require("cosmic.quicksand")
signal.sigaction(signal.SIGALRM, function() end)
local sok, serr = signal.setitimer({
  which = signal.ITIMER_REAL,
  valuesec = 0,
  valuens = 50000000,
  intervalsec = 0,
  intervalns = 0,
})
if not sok then io.stderr:write("setitimer: " .. tostring(serr) .. "\n"); os.exit(1) end
local j, nerr = qs.Box.new({})
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/sleep", "0.3"})
if code == nil then
  io.stderr:write("run nil: " .. tostring(rerr) .. "\n"); os.exit(1)
end
if code ~= 0 then
  io.stderr:write("run exit=" .. tostring(code) .. "\n"); os.exit(1)
end
io.write("ok exit=0\n")
]])
  if not r then return end
  assert(r.ok, "box run interrupted by EINTR mid-wait must still succeed: "
    .. tostring(r.stdout) .. tostring(r.stderr))
  assert(r.stdout:find("ok exit=0"),
    "expected ok, got: " .. tostring(r.stdout))
end
test_run_survives_eintr_during_wait()

-- Setup failures must come back on the error channel as nil + message,
-- not masquerade as a workload exit code (a 126 with the reason only on
-- stderr is indistinguishable from the workload itself failing). A
-- bogus pledge promise fails workload_setup after the fork; run() must
-- return nil and an error naming the pledge step.
local function test_setup_failure_returns_error_not_exit_code()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns and c.pledge) then
    check.skip("box namespaces or pledge unavailable on this host")
    return
  end

  local r = run_script("box_bogus_pledge.lua", [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.Box.new({ proc = { pledge = "bogus_promise" } })
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/true"})
if code ~= nil then
  io.stderr:write("expected nil, got exit=" .. tostring(code) .. "\n"); os.exit(1)
end
if not (type(rerr) == "string" and rerr:find("pledge")) then
  io.stderr:write("error should name pledge: " .. tostring(rerr) .. "\n"); os.exit(1)
end
io.write("ok nil-error: " .. tostring(rerr) .. "\n")
]])
  if not r then return end
  assert(r.ok, "bogus pledge must return nil + pledge error: "
    .. tostring(r.stdout) .. tostring(r.stderr))
  assert(r.stdout:find("ok nil%-error"),
    "expected nil-error report, got: " .. tostring(r.stdout))
end
test_setup_failure_returns_error_not_exit_code()

-- FIX 1: proc.uid without no_new_privs must still set NoNewPrivs.
-- The workload reads /proc/self/status and greps for NoNewPrivs:1.
-- Mapping host uid 65534 into the userns needs privileges an
-- unprivileged runner lacks; the error channel now names that exact
-- failure (uid_map write EPERM), which is the one tolerated skip.
local function test_uid_drop_sets_no_new_privs_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then
    check.skip("box namespaces unavailable on this host")
    return
  end

  local r = run_script("box_nnp_uid.lua", [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.Box.new({ proc = { uid = 65534 } })
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/sh", "-c",
  "grep 'NoNewPrivs:' /proc/self/status | grep -q 1 && echo ok || echo fail"})
if code == nil then
  local e = tostring(rerr)
  if e:find("uid_map") or e:find("setup_userns_maps") then
    io.write("skipped: mapping uid 65534 needs privileges: " .. e .. "\n")
    os.exit(0)
  end
  io.stderr:write("run nil: " .. e .. "\n"); os.exit(1)
end
if code ~= 0 then
  io.stderr:write("run exit=" .. tostring(code) .. "\n"); os.exit(1)
end
]])
  if not r then return end
  assert(r.ok, "uid-drop box must succeed or name the uid_map gap: "
    .. tostring(r.stdout) .. tostring(r.stderr))
  local s = r.stdout
  if s:find("skipped") then
    check.skip("uid_map write needs privileges: " .. s)
    return
  end
  assert(s:find("ok"), "NoNewPrivs should be 1, got: " .. s)
end
test_uid_drop_sets_no_new_privs_subprocess()

-- FIX 2: PID namespace isolation — workload should get a low PID (<= 2).
local function test_pid_namespace_workload_has_low_pid_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns and c.pid_ns) then
    check.skip("box namespaces unavailable on this host")
    return
  end

  local r = run_script("box_pidns.lua", [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.Box.new({})
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/sh", "-c", "test $$ -le 2 && echo ok || echo fail:$$"})
if code == nil then
  io.stderr:write("run nil: " .. tostring(rerr) .. "\n"); os.exit(1)
end
if code ~= 0 then
  io.stderr:write("run exit=" .. tostring(code) .. "\n"); os.exit(1)
end
]])
  if not r then return end
  assert(r.ok, "pid-ns box must succeed: "
    .. tostring(r.stdout) .. tostring(r.stderr))
  assert(r.stdout:find("ok"),
    "workload PID should be <= 2, got: " .. tostring(r.stdout))
end
test_pid_namespace_workload_has_low_pid_subprocess()

-- FIX 2: Opt-out of PID namespace via pid_ns = false still runs.
local function test_pid_namespace_opt_out_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then
    check.skip("box namespaces unavailable on this host")
    return
  end

  local r = run_script("box_nopidns.lua", [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.Box.new({ pid_ns = false })
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/true"})
if code == nil then
  io.stderr:write("run nil: " .. tostring(rerr) .. "\n"); os.exit(1)
end
if code ~= 0 then
  io.stderr:write("run exit=" .. tostring(code) .. "\n"); os.exit(1)
end
io.write("ok\n")
]])
  if not r then return end
  assert(r.ok, "pid_ns opt-out box must succeed: "
    .. tostring(r.stdout) .. tostring(r.stderr))
  assert(r.stdout:find("ok"),
    "expected ok, got: " .. tostring(r.stdout))
end
test_pid_namespace_opt_out_subprocess()
