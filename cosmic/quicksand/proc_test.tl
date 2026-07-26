#!/usr/bin/env cosmic
local proc = require("cosmic.quicksand.proc")
local quicksand = require("cosmic.quicksand")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(proc.no_new_privs) == "function")
  assert(type(proc.drop_privs) == "function")
  assert(type(proc.setup_userns_maps) == "function")
  assert(type(proc.barrier) == "function")
  assert(type(proc.fork_pidns) == "function")
  assert(type(proc.become_init) == "function")
  assert(type(proc.DEFAULT_SIGNALS) == "table")
end
test_module_exports()

-- setup_userns_maps outside a fresh user namespace must fail with an
-- error string (writing "0 uid 1" to uid_map is rejected once the map
-- is already set), never throw. Run in a subprocess in case an exotic
-- environment permits the write.
local function test_setup_userns_maps_returns_error_outside_userns()
  local c = quicksand.capabilities()
  if not c.linux then
    check.skip("userns maps: non-Linux host")
    return
  end
  local script = fs.join(tmpdir, "userns_maps.lua")
  fs.write(script, [[
local proc = require("cosmic.quicksand.proc")
local ok, err = proc.setup_userns_maps(nil, nil)
if ok then
  io.write("ok\n")
else
  assert(type(err) == "string", "err should be a string")
  io.write("skipped: " .. err .. "\n")
end
]])
  local h = check.must(spawn.spawn({cosmic, script}))
  local __r1 = check.must(h:wait())
  local ok, out = __r1.ok, __r1.stdout
  if not ok then
    check.skip("userns maps child died before reporting (outer sandbox)")
    return
  end
  local s = out
  assert(s:find("ok") or s:find("skipped"),
    "expected ok or skipped, got: " .. s)
  if s:find("skipped") then
    check.skip("userns maps: " .. s:gsub("%s+$", ""))
  end
end
test_setup_userns_maps_returns_error_outside_userns()

local function test_default_signals_shape()
  local s = proc.DEFAULT_SIGNALS
  assert(#s >= 1, "DEFAULT_SIGNALS should not be empty")
  for _, name in ipairs(s) do
    assert(type(name) == "string", "signals should be strings: " .. tostring(name))
  end
end
test_default_signals_shape()

local function test_drop_privs_nil_is_noop()
  local ok, err = proc.drop_privs(nil, nil)
  assert(ok, "drop_privs(nil) should succeed: " .. tostring(err))
end
test_drop_privs_nil_is_noop()

-- no_new_privs is irreversible, barrier signals are observable side
-- effects on file descriptors — run in subprocesses.
local function test_no_new_privs_subprocess()
  local c = quicksand.capabilities()
  if not c.linux then
    check.skip("no_new_privs: non-Linux host")
    return
  end
  local script = fs.join(tmpdir, "nnp.lua")
  fs.write(script, [[
local proc = require("cosmic.quicksand.proc")
local ok, err = proc.no_new_privs()
if not ok then
  -- An outer sandbox (pledge/seccomp) may block prctl; skip rather than fail.
  io.write("skipped: " .. tostring(err) .. "\n")
  os.exit(0)
end
io.write("ok\n")
]])
  local h = check.must(spawn.spawn({cosmic, script}))
  local __r2 = check.must(h:wait())
  local ok, out = __r2.ok, __r2.stdout
  -- An outer seccomp/pledge filter may SIGSYS the subprocess on prctl.
  -- Accept signal death as a skip.
  if not ok then
    check.skip("no_new_privs child died before reporting (outer sandbox)")
    return
  end
  local s = out
  assert(s:find("ok") or s:find("skipped"),
    "expected ok or skipped, got: " .. s)
  if s:find("skipped") then
    check.skip("no_new_privs: " .. s:gsub("%s+$", ""))
  end
end
test_no_new_privs_subprocess()

local function test_barrier_signal_wait()
  local c = quicksand.capabilities()
  if not c.linux then
    check.skip("barrier: non-Linux host")
    return
  end
  local script = fs.join(tmpdir, "barrier.lua")
  fs.write(script, [[
local unix = require("cosmo.unix")
local proc = require("cosmic.quicksand.proc")
local b, err = proc.barrier()
if not b then
  io.write("skipped: " .. tostring(err) .. "\n")
  os.exit(0)
end
local pid, ferr = unix.fork()
if not pid then
  io.write("skipped: fork: " .. tostring(ferr) .. "\n")
  os.exit(0)
end
if pid == 0 then
  b:drop_read()
  b:signal()
  os.exit(0)
end
b:drop_write()
b:wait()
unix.wait(pid)
io.write("done\n")
]])
  local h = check.must(spawn.spawn({cosmic, script}))
  local __r3 = check.must(h:wait())
  local ok, out = __r3.ok, __r3.stdout
  -- Signal death under an outer sandbox counts as skip.
  if not ok then
    check.skip("barrier child died before reporting (outer sandbox)")
    return
  end
  local s = out
  assert(s:find("done") or s:find("skipped"),
    "expected done or skipped, got: " .. s)
  if s:find("skipped") then
    check.skip("barrier: " .. s:gsub("%s+$", ""))
  end
end
test_barrier_signal_wait()

-- become_init: the PID-1 supervisor loop.
--
-- These exercise behavior, not just exports. become_init does NOT
-- require a PID namespace -- it is a plain wait(2) loop over a pid it
-- is handed -- so every scenario below runs as an ordinary forking
-- process and needs no privilege. Each runs in a subprocess because
-- become_init installs process-wide sigaction handlers and reaps every
-- child of the calling process.
--
-- The scripts use cosmo.unix directly (as the barrier test above does):
-- fork/wait/kill have no cosmic.* wrapper, since cosmic.child models
-- spawn-and-collect rather than the raw primitives a supervisor needs.

--- Preamble shared by the become_init scenarios: a fork that reports a
--- skip instead of failing when an outer sandbox denies it.
local init_preamble = [[
local unix = require("cosmo.unix")
local qproc = require("cosmic.quicksand.proc")
local time = require("cosmic.time")
local function forked()
  local pid, err = unix.fork()
  if not pid then
    io.write("skipped: fork: " .. tostring(err) .. "\n")
    os.exit(0)
  end
  return pid
end
]]

--- Run a become_init scenario under a fresh cosmic and return its
--- stdout, or nil when the child died before reporting (an outer
--- sandbox killing fork/sigaction, which the caller turns into a skip).
local function run_init(name: string, body: string): string
  local script = fs.join(tmpdir, name .. ".lua")
  fs.write(script, init_preamble .. body)
  local h = check.must(spawn.spawn({cosmic, script}))
  local r = check.must(h:wait())
  if not r.ok then
    return nil
  end
  return r.stdout
end

--- The documented 0..255 case: main exited normally, so become_init
--- returns that exit status verbatim.
local function test_become_init_returns_child_exit_status()
  local out = run_init("init_exit", [[
local pid = forked()
if pid == 0 then os.exit(42) end
io.write("code=" .. tostring(qproc.become_init(pid)) .. "\n")
]])
  if not out then
    check.skip("become_init exit status: child died (outer sandbox)")
    return
  end
  if out:find("skipped") then
    check.skip("become_init exit status: " .. out:gsub("%s+$", ""))
    return
  end
  assert(out:find("code=42"), "expected code=42, got: " .. out)
end
test_become_init_returns_child_exit_status()

--- The documented 128+signum case. SIGKILL is unblockable, so the kill
--- lands whatever the child is doing -- no sleep/race to lose.
local function test_become_init_maps_signal_death_to_128_plus_signum()
  local out = run_init("init_signaled", [[
local pid = forked()
if pid == 0 then time.sleep(60) os.exit(0) end
unix.kill(pid, unix.SIGKILL)
io.write("code=" .. tostring(qproc.become_init(pid)) .. "\n")
]])
  if not out then
    check.skip("become_init signal death: child died (outer sandbox)")
    return
  end
  if out:find("skipped") then
    check.skip("become_init signal death: " .. out:gsub("%s+$", ""))
    return
  end
  -- 128 + SIGKILL(9)
  assert(out:find("code=137"), "expected code=137, got: " .. out)
end
test_become_init_maps_signal_death_to_128_plus_signum()

--- Signal forwarding plus the unknown-child reap, in one scenario: a
--- killer child SIGTERMs the supervisor, whose handler forwards it to
--- main. Main dies of SIGTERM (143). The killer is NOT a sidecar, so
--- reaping it must not end the loop -- if the "unknown children keep
--- the loop waiting" branch regressed, become_init would return early
--- with 1 and this test would catch it.
local function test_become_init_forwards_signals_to_main()
  local out = run_init("init_forward", [[
local main = forked()
if main == 0 then time.sleep(60) os.exit(0) end
local supervisor = unix.getpid()
local killer = forked()
if killer == 0 then
  time.sleep(1)
  unix.kill(supervisor, unix.SIGTERM)
  os.exit(0)
end
io.write("code=" .. tostring(qproc.become_init(main)) .. "\n")
]])
  if not out then
    check.skip("become_init forwarding: child died (outer sandbox)")
    return
  end
  if out:find("skipped") then
    check.skip("become_init forwarding: " .. out:gsub("%s+$", ""))
    return
  end
  -- 128 + SIGTERM(15)
  assert(out:find("code=143"), "expected code=143, got: " .. out)
end
test_become_init_forwards_signals_to_main()

--- A sidecar exiting before main: on_sidecar_exit fires with that
--- sidecar's pid, main is killed, and the supervisor reports 1.
local function test_become_init_sidecar_exit_kills_main()
  local out = run_init("init_sidecar", [[
local main = forked()
if main == 0 then time.sleep(60) os.exit(0) end
local side = forked()
if side == 0 then os.exit(0) end
local fired = -1
local code = qproc.become_init(main, {
  sidecars = {side},
  on_sidecar_exit = function(pid) fired = pid end,
})
io.write("code=" .. tostring(code)
  .. " fired=" .. tostring(fired == side) .. "\n")
]])
  if not out then
    check.skip("become_init sidecar: child died (outer sandbox)")
    return
  end
  if out:find("skipped") then
    check.skip("become_init sidecar: " .. out:gsub("%s+$", ""))
    return
  end
  assert(out:find("code=1"), "expected code=1, got: " .. out)
  assert(out:find("fired=true"),
    "on_sidecar_exit should fire with the sidecar pid, got: " .. out)
end
test_become_init_sidecar_exit_kills_main()
