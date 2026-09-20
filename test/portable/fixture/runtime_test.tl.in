local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")

local function test_runtime_identity_change_runs_again()
  local counter = assert(Env.get("COSMIC_FIXTURE_COUNTER"))
  local target = assert(Store.meta("host"))
  local core = assert(Store.meta("host_image"))
  local basis = assert(Store.meta("runtime_basis"))
  local runtime = assert(Store.meta("runtime"))
  local artifact = assert(Store.meta("artifact"))
  assert(Store.meta("runtime_context") == "portable-v1")
  assert(#core == 64 and core:match("^[0-9a-f]+$") ~= nil)
  assert(#basis == 64 and basis:match("^[0-9a-f]+$") ~= nil)
  assert(#runtime == 64 and runtime:match("^[0-9a-f]+$") ~= nil)
  assert(runtime ~= basis)
  assert(Proc.executable() == artifact)
  assert(sys.executable() == artifact)
  local before = Fs.read(counter) or ""
  assert(Fs.write(counter, before .. target .. " " .. core .. " " ..
    basis .. " " .. runtime .. "\n"))
end
