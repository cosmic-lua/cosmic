--- What `spawn`'s `grants` (core/process.h) refuses before any ruleset is
--- made, and what the Landlock ABI query answers where there is none, as
--- core/grants_child_test.tl holds a live child to the ruleset the grants
--- build. A degenerate grant raises at the argument check, and a kernel
--- with no Landlock answers the query with a reason and an errno, on every
--- platform, so none of it needs a sandbox.

local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
local StandIn = require("cosmic.stand_in")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

--- Nothing is read beyond the closure: the stand-in is built in the
--- test's own directory and never started.
Test.policy{}

local process = require("cosmic.internal.process")

--- Starts `probe` under a sandbox of the one field `name` holding `value`,
--- as an untyped caller could: whether the start raised, and why.
local function raised(probe: string, name: string, value: any): boolean, string
  local sandbox: mut {string:any} = {}
  sandbox[name] = value
  local started, why = pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil, -- checked: overload_none
    sandbox as raw_process.Sandbox) -- checked: cast_refused
  return not started, tostring(why)
end

local function test_a_degenerate_grant_raises(tmp: string)
  local probe = assert(StandIn.build(tmp .. "/stand-in"))
  local function raises(grants: any): boolean
    return (raised(probe, "grants", grants))
  end
  assert(raises({ { path = probe, access = "rq" } }), "a letter that is none")
  assert(raises({ { path = probe, access = "" } }), "no letters")
  assert(raises({ { path = probe, access = "R" } }), "letters are lowercase")
  assert(raises({ { path = "", access = "r" } }), "an empty path")
  assert(raises({ { access = "r" } }), "no path")
  assert(raises({ { path = probe } }), "no access")
  assert(raises({ { path = 1, access = "r" } }), "a path that is no string")
  assert(raises({ probe }), "a grant that is no table")
  assert(raises("r"), "grants that are no list")
  assert(raises({ { path = "a\0b", access = "r" } }), "a path with a NUL")
end

--- A sandbox naming an option spawn no longer has is refused, so a
--- caller that asked for that hold never gets an unconfined child.
local function test_a_sandbox_naming_a_gone_option_raises(tmp: string)
  local probe = assert(StandIn.build(tmp .. "/stand-in"))
  local none: {string} = {}
  local ruleset_raised, ruleset_why = raised(probe, "ruleset", 0)
  local pledge_raised, pledge_why = raised(probe, "pledge", none)
  for _, said in ipairs({ ruleset_why, pledge_why }) do
    assert(said:find("`grants` and `promises`", 1, true) ~= nil, said)
  end
  assert(ruleset_raised and pledge_raised)
end

local function test_the_landlock_abi_is_a_version_or_a_refusal(_tmp: string)
  local abi, trouble, number = process.landlock_abi()
  if abi == nil then
    assert(type(trouble) == "string" and math.type(number) == "integer", "a failure says why")
    return
  end
  assert(math.type(abi) == "integer" and abi >= 1, "a version: " .. tostring(abi))
end
