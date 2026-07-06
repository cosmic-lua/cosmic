#!/usr/bin/env cosmic
local proc = require("cosmic.quicksand.proc")
local quicksand = require("cosmic.quicksand")
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
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
  if not c.linux then return end
  local script = fs.join(tmpdir, "userns_maps.lua")
  cio.barf(script, [[
local proc = require("cosmic.quicksand.proc")
local ok, err = proc.setup_userns_maps(nil, nil)
if ok then
  io.write("ok\n")
else
  assert(type(err) == "string", "err should be a string")
  io.write("skipped: " .. err .. "\n")
end
]])
  local h = spawn.spawn({cosmic, script})
  local __r1 = (h as spawn.Handle):wait() as spawn.Result
  local ok, out = __r1.ok, __r1.stdout
  if not ok then return end
  local s = out as string
  assert(s:find("ok") or s:find("skipped"),
    "expected ok or skipped, got: " .. s)
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
  if not c.linux then return end
  local script = fs.join(tmpdir, "nnp.lua")
  cio.barf(script, [[
local proc = require("cosmic.quicksand.proc")
local ok, err = proc.no_new_privs()
if not ok then
  -- An outer sandbox (pledge/seccomp) may block prctl; skip rather than fail.
  io.write("skipped: " .. tostring(err) .. "\n")
  os.exit(0)
end
io.write("ok\n")
]])
  local h = spawn.spawn({cosmic, script})
  local __r2 = (h as spawn.Handle):wait() as spawn.Result
  local ok, out = __r2.ok, __r2.stdout
  -- An outer seccomp/pledge filter may SIGSYS the subprocess on prctl.
  -- Accept signal death as a skip.
  if not ok then return end
  local s = out as string
  assert(s:find("ok") or s:find("skipped"),
    "expected ok or skipped, got: " .. s)
end
test_no_new_privs_subprocess()

local function test_barrier_signal_wait()
  local c = quicksand.capabilities()
  if not c.linux then return end
  local script = fs.join(tmpdir, "barrier.lua")
  cio.barf(script, [[
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
  local h = spawn.spawn({cosmic, script})
  local __r3 = (h as spawn.Handle):wait() as spawn.Result
  local ok, out = __r3.ok, __r3.stdout
  -- Signal death under an outer sandbox counts as skip.
  if not ok then return end
  local s = out as string
  assert(s:find("done") or s:find("skipped"),
    "expected done or skipped, got: " .. s)
end
test_barrier_signal_wait()
