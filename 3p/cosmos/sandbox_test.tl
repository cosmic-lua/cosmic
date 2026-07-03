#!/usr/bin/env cosmic

-- Verifies the vendored cosmo.sandbox modules (3p/cosmos/sandbox/*.lua,
-- embedded at /zip/.lua/cosmo/sandbox/) load from this binary and expose
-- their documented surface. Behavior is covered by the quicksand tests;
-- this guards the vendoring itself (a missing or shadowed module fails
-- here even on hosts without namespace support).

local function test_umbrella()
  local sandbox = require("cosmo.sandbox")
  assert(type(sandbox.capabilities) == "function", "sandbox.capabilities missing")
  assert(type(sandbox.is_supported) == "function", "sandbox.is_supported missing")
  local caps = sandbox.capabilities()
  assert(type(caps) == "table", "capabilities() should return a table")
  for _, key in ipairs({"linux", "user_ns", "net_ns", "landlock", "pledge", "unveil"}) do
    assert(type((caps as {string: any})[key]) == "boolean", "capabilities()." .. key)
  end
end
test_umbrella()

local function test_submodules()
  local want: {string: {string}} = {
    ["cosmo.sandbox.fs"] = {"pivot_to", "pivot_to_or_exit"},
    ["cosmo.sandbox.netns"] = {"bring_up", "control_socket"},
    ["cosmo.sandbox.proc"] = {"setup_userns_maps"},
    ["cosmo.sandbox.landlock"] = {"restrict"},
    ["cosmo.sandbox.proxy"] = {"start", "new"},
  }
  for name, fns in pairs(want) do
    local mod = require(name)
    assert(type(mod) == "table", name .. " should be a table")
    for _, fn in ipairs(fns) do
      local got = (mod as {string: any})[fn]
      assert(type(got) == "function", name .. "." .. fn .. " missing")
    end
  end
end
test_submodules()

local function test_vendored_source_embedded()
  local cosmo = require("cosmo")
  for _, name in ipairs({"init", "fs", "netns", "proc", "landlock", "proxy"}) do
    local path = "/zip/.lua/cosmo/sandbox/" .. name .. ".lua"
    local data = cosmo.Slurp(path)
    assert(type(data) == "string" and #data > 0, path .. " not embedded")
  end
end
test_vendored_source_embedded()
