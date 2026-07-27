#!/usr/bin/env cosmic
-- tl.d.tl is GENERATED into o/_types/types_gen/ and not committed, so there is no
-- drift to test for. What is tested is the extractor: the erasure rules
-- below are the load-bearing part, and tl_conformance_test.tl checks the
-- result against tl's own source.

local fs = require("cosmic.fs")
local gentl = require("_types.gentl")

-- `cosmic --make fetch` unpacks a pin beside the pin, so tl's tarball
-- lands whole in `o/3p/tl/`.
local staged_tl = fs.join("o", "3p", "tl", "tl.tl")

-- Extraction has to survive the real tl source, not just the erasure
-- cases below: a shim that fails to generate is a tree that cannot
-- type check.
local function test_generates_from_staged_source()
  local source, rerr = fs.read(staged_tl)
  assert(source, "staged tl.tl should be readable: " .. tostring(rerr))
  local generated, gerr = gentl.generate(source)
  assert(generated, "generation should succeed: " .. tostring(gerr))
  assert(#generated > 0, "generated shim should not be empty")
end
test_generates_from_staged_source()

-- The erasure rules are the load-bearing part of extraction; pin them.
local function test_erasure_rules()
  local cases: {string: string} = {
    ["string"] = "string",
    ["GenTarget"] = "string",
    ["boolean | GenCompat"] = "boolean | string",
    ["tl.Node"] = "any",
    ["Env"] = "any",
    ["{Token}"] = "{Token}",
    ["{Error}"] = "{Error}",
    ["{WarningKind:boolean}"] = "{string: boolean}",
    ["GenerateOptions"] = "any",
    ["EnvOptions"] = "EnvOptions",
  }
  for input, want in pairs(cases) do
    local got = gentl.erase(input)
    assert(got == want,
      "erase(" .. input .. "): want " .. want .. ", got " .. tostring(got))
  end
end
test_erasure_rules()
