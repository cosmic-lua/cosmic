#!/usr/bin/env cosmic
-- The committed _types/tl.d.tl must equal gentl.tl's output from the
-- staged tl source byte-for-byte (the gentype pattern): the shim cannot
-- drift from tl's real API without this test failing. The staged source
-- is reached through the o/tl/.staged symlink; the Makefile makes this
-- test depend on tl staging.

local fs = require("cosmic.fs")
local gentl = require("_types.gentl")

-- `cosmic --make fetch` unpacks a pin beside the pin, so tl's tarball
-- lands whole in `o/3p/tl/`. The Makefile's fetch pipeline stages to a
-- version-stamped directory and symlinks `o/tl/.staged` at it; both are
-- live while the bridge is, so ask which one is there. The fallback
-- goes with the Makefile.
local fetched_tl = fs.join("o", "3p", "tl", "tl.tl")
local staged_tl = fs.isfile(fetched_tl) and fetched_tl
or fs.join("o", "tl", ".staged", "tl.tl")

local function test_generated_matches_committed()
  local source, rerr = fs.read(staged_tl)
  assert(source, "staged tl.tl should be readable: " .. tostring(rerr))
  local generated, gerr = gentl.generate(source)
  assert(generated, "generation should succeed: " .. tostring(gerr))
  local committed = assert(fs.read("_types/tl.d.tl"))
  assert(generated == committed,
    "_types/tl.d.tl differs from generated output; "
    .. "run `bin/make regen-tl-types` and commit the result")
end
test_generated_matches_committed()

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
