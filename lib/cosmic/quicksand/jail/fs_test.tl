#!/usr/bin/env cosmic
local jfs = require("cosmic.quicksand.jail.fs")
local landlock = require("cosmic.landlock")

local function find_rule(rules: {any}, path: string): {string: any}
  for _, r in ipairs(rules) do
    local rr = r as {string: any}
    if rr.path == path then return rr end
  end
  return nil
end

local function test_ro_produces_read_exec()
  local opts = jfs.plan_landlock({ro = {"/usr"}})
  local r = find_rule(opts.rules as {any}, "/usr")
  assert(r, "expected /usr rule")
  local want = landlock.READ | landlock.EXEC
  assert((r.access as integer) == want, "got access: " .. tostring(r.access))
end
test_ro_produces_read_exec()

local function test_rw_produces_rw()
  local opts = jfs.plan_landlock({rw = {"/tmp"}})
  local r = find_rule(opts.rules as {any}, "/tmp")
  assert(r)
  assert((r.access as integer) == landlock.RW,
    "got access: " .. tostring(r.access))
end
test_rw_produces_rw()

local function test_overlap_ored()
  -- A path listed in both ro and rw should have both masks OR'd.
  local opts = jfs.plan_landlock({ro = {"/shared"}, rw = {"/shared"}})
  local r = find_rule(opts.rules as {any}, "/shared")
  assert(r)
  local want = (landlock.READ | landlock.EXEC) | landlock.RW
  assert((r.access as integer) == want,
    "got access: " .. tostring(r.access))
end
test_overlap_ored()

local function test_empty_deny_all()
  local opts = jfs.plan_landlock(nil)
  assert(#(opts.rules as {any}) == 0, "nil fs → no rules (deny-all)")
  assert(opts.handled == landlock.ALL)
  assert(opts.no_new_privs == true)
end
test_empty_deny_all()

local function test_handled_is_all()
  local opts = jfs.plan_landlock({ro = {"/usr"}})
  assert(opts.handled == landlock.ALL, "handled should be ALL for max portability")
end
test_handled_is_all()

local function test_order_preserved()
  local opts = jfs.plan_landlock({ro = {"/a", "/b", "/c"}})
  local rules = opts.rules as {any}
  assert((rules[1] as {string: any}).path == "/a")
  assert((rules[2] as {string: any}).path == "/b")
  assert((rules[3] as {string: any}).path == "/c")
end
test_order_preserved()
