#!/usr/bin/env cosmic
local proc = require("cosmic.quicksand.proc")
local quicksand = require("cosmic.quicksand")
local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(proc.no_new_privs) == "function")
  assert(type(proc.drop_privs) == "function")
  assert(type(proc.barrier) == "function")
  assert(type(proc.become_init) == "function")
  assert(type(proc.DEFAULT_SIGNALS) == "table")
end
test_module_exports()

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
  local script = path.join(tmpdir, "nnp.lua")
  cosmo.Barf(script, [[
local proc = require("cosmic.quicksand.proc")
local ok, err = proc.no_new_privs()
if not ok then io.stderr:write("no_new_privs: " .. tostring(err) .. "\n"); os.exit(1) end
io.write("ok\n")
]])
  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "subprocess failed: " .. tostring(out))
  assert((out as string):find("ok"), "expected ok, got: " .. tostring(out))
end
test_no_new_privs_subprocess()

local function test_barrier_signal_wait()
  local c = quicksand.capabilities()
  if not c.linux then return end
  local script = path.join(tmpdir, "barrier.lua")
  cosmo.Barf(script, [[
local unix = require("cosmo.unix")
local proc = require("cosmic.quicksand.proc")
local b, err = proc.barrier()
if not b then io.stderr:write("barrier: " .. tostring(err) .. "\n"); os.exit(1) end
local pid = assert(unix.fork())
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
  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "subprocess failed: " .. tostring(out))
  assert((out as string):find("done"), "expected done, got: " .. tostring(out))
end
test_barrier_signal_wait()
