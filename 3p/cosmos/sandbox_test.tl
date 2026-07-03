#!/usr/bin/env cosmic

-- Verifies the vendored cosmo.sandbox modules (3p/cosmos/sandbox/*.lua,
-- embedded at /zip/.lua/cosmo/sandbox/) load from this binary and expose
-- their documented surface. Behavior is covered by the quicksand tests;
-- this guards the vendoring itself (a missing or shadowed module fails
-- here even on hosts without namespace support).
--
-- netns, landlock, and the capabilities umbrella have been rewritten in
-- Teal (cosmic.quicksand.netns, cosmic.landlock, cosmic.quicksand); the
-- modules below are the remainder, awaiting the same treatment.

local function test_submodules()
  local want: {string: {string}} = {
    ["cosmo.sandbox.fs"] = {"pivot_to", "pivot_to_or_exit"},
    ["cosmo.sandbox.proc"] = {"setup_userns_maps"},
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
  for _, name in ipairs({"fs", "proc", "proxy"}) do
    local path = "/zip/.lua/cosmo/sandbox/" .. name .. ".lua"
    local data = cosmo.Slurp(path)
    assert(type(data) == "string" and #data > 0, path .. " not embedded")
  end
end
test_vendored_source_embedded()
