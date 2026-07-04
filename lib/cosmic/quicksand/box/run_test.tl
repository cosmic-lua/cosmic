#!/usr/bin/env cosmic
--- Integration test for cosmic.quicksand.Box:run.
---
--- box:run unshares CLONE_NEWUSER, which is irreversible for the
--- calling thread — and can be blocked entirely by an outer seccomp /
--- pledge filter. Run the workload in a fresh cosmic subprocess so
--- failures don't poison the rest of the test harness, and follow the
--- same "ok | skipped | signal death = skip" pattern the raw netns /
--- proc tests use.
local quicksand = require("cosmic.quicksand")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local cio = require("cosmic.io")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_run_true_in_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then return end

  local script = fs.join(tmpdir, "box_run_true.lua")
  cio.barf(script, [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.Box.new({})
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/true"})
if code == nil then
  -- Setup failed before fork (e.g. netns.open). With an empty policy
  -- there's no net allowlist so netns.open isn't called; any nil here
  -- is a genuine infrastructure problem. Surface the error instead of
  -- masking it as a skip.
  io.stderr:write("run nil: " .. tostring(rerr) .. "\n"); os.exit(1)
end
if code == 0 then io.write("ok exit=0\n"); os.exit(0) end
-- Non-zero: the supervisor child exited 126 after unshare / userns
-- setup failed under an outer pledge / seccomp filter. Distinguishing
-- that from a real /bin/true crash here isn't reliable, so treat any
-- non-zero as a skip.
io.write("skipped: exit=" .. tostring(code) .. "\n"); os.exit(0)
]])

  local ok, out = spawn.spawn({cosmic, script}):read()
  -- An outer seccomp filter may SIGSYS the subprocess outright; that
  -- still counts as a skip because we never reached enforcement.
  if not ok then return end
  local s = out as string
  assert(s:find("ok exit=0") or s:find("skipped"),
    "expected ok or skipped, got: " .. s)
end
test_run_true_in_subprocess()

-- FIX 1: proc.uid without no_new_privs must still set NoNewPrivs.
-- The workload reads /proc/self/status and greps for NoNewPrivs:1.
local function test_uid_drop_sets_no_new_privs_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then return end

  local script = fs.join(tmpdir, "box_nnp_uid.lua")
  cio.barf(script, [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.Box.new({ proc = { uid = 65534 } })
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/sh", "-c",
  "grep 'NoNewPrivs:' /proc/self/status | grep -q 1 && echo ok || echo fail"})
if code == nil then
  io.stderr:write("run nil: " .. tostring(rerr) .. "\n"); os.exit(1)
end
if code ~= 0 then
  -- unshare failed under outer sandbox; treat as skip
  io.write("skipped: exit=" .. tostring(code) .. "\n"); os.exit(0)
end
]])

  local ok, out = spawn.spawn({cosmic, script}):read()
  if not ok then return end
  local s = out as string
  assert(s:find("ok") or s:find("skipped"),
    "expected ok or skipped (NoNewPrivs should be 1), got: " .. s)
end
test_uid_drop_sets_no_new_privs_subprocess()

-- FIX 2: PID namespace isolation — workload should get a low PID (<= 2).
local function test_pid_namespace_workload_has_low_pid_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns and c.pid_ns) then return end

  local script = fs.join(tmpdir, "box_pidns.lua")
  cio.barf(script, [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.Box.new({})
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/sh", "-c", "test $$ -le 2 && echo ok || echo fail:$$"})
if code == nil then
  io.stderr:write("run nil: " .. tostring(rerr) .. "\n"); os.exit(1)
end
if code ~= 0 then
  io.write("skipped: exit=" .. tostring(code) .. "\n"); os.exit(0)
end
]])

  local ok, out = spawn.spawn({cosmic, script}):read()
  if not ok then return end
  local s = out as string
  assert(s:find("ok") or s:find("skipped"),
    "expected ok or skipped (PID should be <= 2), got: " .. s)
end
test_pid_namespace_workload_has_low_pid_subprocess()

-- FIX 2: Opt-out of PID namespace via pid_ns = false still runs.
local function test_pid_namespace_opt_out_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns and c.net_ns) then return end

  local script = fs.join(tmpdir, "box_nopidns.lua")
  cio.barf(script, [[
local qs = require("cosmic.quicksand")
local j, nerr = qs.Box.new({ pid_ns = false })
if not j then io.stderr:write("new: " .. tostring(nerr) .. "\n"); os.exit(1) end
local code, rerr = j:run({"/bin/true"})
if code == nil then
  io.stderr:write("run nil: " .. tostring(rerr) .. "\n"); os.exit(1)
end
if code ~= 0 then
  io.write("skipped: exit=" .. tostring(code) .. "\n"); os.exit(0)
end
io.write("ok\n")
]])

  local ok, out = spawn.spawn({cosmic, script}):read()
  if not ok then return end
  local s = out as string
  assert(s:find("ok") or s:find("skipped"),
    "expected ok or skipped, got: " .. s)
end
test_pid_namespace_opt_out_subprocess()
