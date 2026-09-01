#!/usr/bin/env cosmic
--- Integration test for cosmic.quicksand.Box:run.
---
--- box:run unshares CLONE_NEWUSER, which is irreversible for the
--- calling thread, so every workload runs in a fresh cosmic subprocess.
--- capabilities().user_ns is a real scratch-child unshare probe, so
--- when the guard passes, setup is expected to succeed: setup failures
--- surface as nil + error over Box:run's error pipe and are hard test
--- failures, not skips. The only tolerated skips are named, specific
--- conditions (an outer seccomp filter SIGSYS-ing the subprocess, or a
--- uid_map write that needs privileges this test does not have).
local quicksand = require("cosmic.quicksand")
local fs = require("cosmic.fs")
local child = require("cosmic.child")
local net = require("cosmic.net")
local check = require("cosmic.check")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Run `script` in a fresh cosmic subprocess. Returns the Result, or nil
-- after registering a strict skip when the subprocess was killed by a
-- signal (an outer seccomp filter SIGSYS-ing a namespace syscall).
local function run_script(name: string, body: string): child.Result
  local script = fs.join(tmpdir, name)
  assert(fs.write(script, body))
  local h = check.must(child.start({cosmic, script}))
  local r = check.must(h:wait())
  if r.signal ~= nil then
    check.enforce_skip("box subprocess killed by signal " .. tostring(r.signal)
      .. " (outer sandbox)", true)
    return nil
  end
  return r
end

local function test_run_true_in_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then
    check.enforce_skip("box namespaces unavailable on this host")
    return
  end

  -- user_ns probed true above, so setup must succeed: a nil + error
  -- return or a non-zero exit from /bin/true is a real failure.
  local r = run_script("box_run_true.lua", [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.new({})
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

-- A one-shot SIGALRM fires ~50ms into a workload that sleeps 300ms,
-- guaranteeing wait(pid) is interrupted mid-block by EINTR; run() must
-- retry the wait and still return the workload's real exit code, not
-- feed the errno STRING to WIFEXITED.
local function test_run_survives_eintr_during_wait()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then
    check.enforce_skip("box namespaces unavailable on this host")
    return
  end

  local r = run_script("box_run_eintr.lua", [[
local signal = require("cosmic.signal")
local qs = require("cosmic.quicksand")
signal.sigaction(signal.SIGALRM, function() end)
local sok, serr = signal.setitimer({
  which = signal.ITIMER_REAL,
  value_ms = 50,
  interval_ms = 0,
})
if not sok then io.stderr:write("setitimer: " .. tostring(serr) .. "\n"); os.exit(1) end
local j, nerr = qs.new({})
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

-- A typo'd sys policy must be rejected at Box.new — construction time,
-- before any fork — with an error naming the bad promise, via
-- cosmic.sandbox's validator, so it never surfaces post-fork as an
-- opaque exit 126.
local function test_bogus_sys_promise_rejected_at_new()
  local err = check.refuses(quicksand.new, {sys = {promises = "stdio bogus_promise"}})
  assert(err:find("bogus_promise", 1, true),
    "error should name the bad promise: " .. err)
end

-- Setup failures must come back on the error channel as nil + message,
-- not masquerade as a workload exit code (a 126 with the reason only on
-- stderr is indistinguishable from the workload itself failing). A cwd
-- that does not exist fails workload_setup after the fork; run() must
-- return nil and an error naming the chdir step.
local function test_setup_failure_returns_error_not_exit_code()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then
    check.enforce_skip("box namespaces unavailable on this host")
    return
  end

  local r = run_script("box_bad_cwd.lua", [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.new({ cwd = "/nonexistent-quicksand-run-test" })
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/true"})
if code ~= nil then
  io.stderr:write("expected nil, got exit=" .. tostring(code) .. "\n"); os.exit(1)
end
if not (type(rerr) == "string" and rerr:find("chdir")) then
  io.stderr:write("error should name chdir: " .. tostring(rerr) .. "\n"); os.exit(1)
end
io.write("ok nil-error: " .. tostring(rerr) .. "\n")
]])
  if not r then return end
  assert(r.ok, "bad cwd must return nil + chdir error: "
    .. tostring(r.stdout) .. tostring(r.stderr))
  assert(r.stdout:find("ok nil%-error"),
    "expected nil-error report, got: " .. tostring(r.stdout))
end

-- proc.uid without no_new_privs must still set NoNewPrivs.
-- The workload reads /proc/self/status and greps for NoNewPrivs:1.
-- Mapping host uid 65534 into the userns needs privileges an
-- unprivileged runner lacks; the error channel names that exact
-- failure (uid_map write EPERM), which is the one tolerated skip.
local function test_uid_drop_sets_no_new_privs_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then
    check.enforce_skip("box namespaces unavailable on this host")
    return
  end

  local r = run_script("box_nnp_uid.lua", [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.new({ proc = { uid = 65534 } })
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
    check.enforce_skip("uid_map write needs privileges: " .. s)
    return
  end
  assert(s:find("ok"), "NoNewPrivs should be 1, got: " .. s)
end

-- PID namespace isolation — workload should get a low PID (<= 2).
local function test_pid_namespace_workload_has_low_pid_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns and c.pid_ns) then
    check.enforce_skip("box namespaces unavailable on this host")
    return
  end

  local r = run_script("box_pidns.lua", [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.new({})
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

-- The Landlock net tier backs a Box's network policy when net_ns is
-- unavailable: forcing net_ns false (the only deterministic way to
-- exercise "netns cannot start" — a live host is always either net_ns-
-- capable or lacks landlock outright, never usefully one without the
-- other, the same reasoning landlock_net_test.tl's ABI mock uses)
-- proves the box still runs, confined to the proxy port rather than
-- refusing outright. `srv_other` stands in for a host the workload
-- must NOT be able to reach directly, bypassing the proxy's own
-- hostname allowlist.
local function test_landlock_net_backstop_when_net_ns_unavailable()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.landlock_net) then
    check.enforce_skip("landlock net tier unavailable (needs Linux Landlock ABI >= 4)")
    return
  end

  local srv_other = check.must(net.listen_tcp("127.0.0.1", 0))
  local port_other = check.must(srv_other:local_endpoint()).port

  local workload = [[
local net = require("cosmic.net")
local proxy_url = os.getenv("HTTP_PROXY") or ""
local proxy_port = tonumber(proxy_url:match(":(%d+)$"))
if not proxy_port then io.write("no-proxy-port\n") os.exit(1) end
local c1 = net.dial("127.0.0.1", proxy_port)
io.write(c1 and "allowed-ok\n" or "allowed-fail\n")
if c1 then c1:close() end
local c2 = net.dial("127.0.0.1", ]] .. tostring(port_other) .. [[)
io.write(c2 and "denied-leaked\n" or "denied-blocked\n")
if c2 then c2:close() end
]]

  local r = run_script("box_net_backstop.lua", string.format([[
local qs = require("cosmic.quicksand")
local real = qs.capabilities()
qs.capabilities = function()
  local c = {}
  for k, v in pairs(real) do c[k] = v end
  c.net_ns = false
  return c
end
local j, nerr = qs.new({ net = { allow = {} } })
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
if j:net_tier() ~= "landlock" then
  io.stderr:write("net_tier: expected 'landlock', got " .. tostring(j:net_tier()) .. "\n")
  os.exit(1)
end
local code, rerr = j:run({%q, "-e", %q})
if code == nil then
  io.stderr:write("run nil: " .. tostring(rerr) .. "\n"); os.exit(1)
end
if code ~= 0 then
  io.stderr:write("run exit=" .. tostring(code) .. "\n"); os.exit(1)
end
io.write("ok\n")
]], cosmic, workload))
  check.must(srv_other:close())
  if not r then return end
  assert(r.ok, "netns-less landlock net backstop box must succeed: "
    .. tostring(r.stdout) .. tostring(r.stderr))
  local s = r.stdout
  assert(s:find("allowed-ok", 1, true), "connect to the proxy port must be allowed: " .. s)
  assert(s:find("denied-blocked", 1, true),
    "connect to a port outside the backstop must be denied: " .. s)
  check.enforced("quicksand box landlock net backstop (no net_ns)")
end

-- net_tier() must reflect this host's REAL capabilities, not a mock:
-- with net_ns actually available, the expected answer is "netns" alone
-- or "netns+landlock" depending on whether this kernel's real
-- landlock_net also holds — derived here from the same Capabilities
-- record capabilities() returns, not asserted as a fixed constant, so
-- the test stays correct across hosts with either ABI.
local function test_net_tier_reflects_real_capabilities()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then
    check.enforce_skip("box namespaces unavailable on this host")
    return
  end
  local j = check.must(quicksand.new({net = {allow = {["example.com:443"] = {}}}}))
  local want = c.landlock_net and "netns+landlock" or "netns"
  assert(j:net_tier() == want,
    "expected net_tier " .. want .. ", got " .. tostring(j:net_tier()))
end

-- Opt-out of PID namespace via pid_ns = false still runs.
local function test_pid_namespace_opt_out_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then
    check.enforce_skip("box namespaces unavailable on this host")
    return
  end

  local r = run_script("box_nopidns.lua", [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.new({ pid_ns = false })
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
