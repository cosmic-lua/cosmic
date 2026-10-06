local Assertions = require("build.assertions")

--- Each of these runs in a worker that has installed the counting `assert`
--- as the global, so `assert` below is the one under test.

local function tail(condition: any, message?: any): any...
  return assert(condition, message)
end

local function position_of(f: function(): any...): any
  local ok, message = pcall(f)
  assert(not ok)
  return message
end

local function test_it_counts_each_call_through_a_tail_call_a_helper_and_a_capture()
  local capture = assert
  Assertions.reset()
  local before = Assertions.count()
  assert(true)
  capture(true)
  tail(true)
  pcall(tail, false, "x")
  assert(Assertions.count() == before + 4, "counted " .. Assertions.count())
end

local function test_reset_starts_from_zero()
  assert(true)
  Assertions.reset()
  assert(Assertions.count() == 0)
end

local function test_it_answers_every_argument_of_a_passing_call()
  local a, b, c = assert(1, "two", 3)
  assert(a == 1 and b == "two" and c == 3)
  assert(select("#", assert(true, nil, nil)) == 3)
end

local function test_a_failing_call_in_tail_position_reports_the_helpers_position()
  local message = position_of(function(): any... return tail(false, "boom") end)
  assert(tostring(message):find("assertions_test:7: boom", 1, true), tostring(message))
end

local function test_a_failing_call_reports_the_position_of_its_caller()
  local message = position_of(function() assert(false, "plain") end)
  assert(tostring(message):find("assertions_test:", 1, true) and tostring(message):find(": plain", 1, true),
    tostring(message))
end

local function test_a_missing_message_is_assertion_failed()
  local message = position_of(function() assert(false) end)
  assert(tostring(message):find(": assertion failed!", 1, true), tostring(message))
  local nilled = position_of(function() assert(nil) end)
  assert(tostring(nilled):find(": assertion failed!", 1, true), tostring(nilled))
end

local function test_arguments_after_the_message_are_dropped_from_a_failure()
  local message = position_of(function() assert(nil, "m", "extra", 3) end)
  assert(tostring(message):find(": m$"), tostring(message))
end

local function test_a_message_that_is_not_a_string_is_raised_as_it_is()
  local value = {}
  assert(position_of(function() assert(false, value) end) == value)
  assert(position_of(function() assert(false, 42) end) == 42)
end

local function test_no_condition_is_a_bad_argument()
  local message = position_of(function() (assert as function)() end)
  assert(tostring(message):find("bad argument #1 to 'assert' (value expected)", 1, true), tostring(message))
end

--- Values packed with their count, as `table.pack` gives them.
local record Packed
  {any}
  n: integer
end

--- What `f` does with `...`, called from this one line so that a position
--- in a failure's message is the same whichever `assert` it is.
local function outcome(f: function(...: any): any..., ...: any): Packed
  return table.pack(pcall(function(...: any): any... return f(...) end, ...)) as Packed
end

--- The same, with the `assert` called in tail position.
local function tail_outcome(f: function(...: any): any..., ...: any): Packed
  local function call(...: any): any... return f(...) end
  return table.pack(pcall(call, ...)) as Packed
end

local function same(a: Packed, b: Packed, case: string)
  local an, bn = a.n, b.n
  assert(an == bn, case .. ": " .. tostring(an) .. " results against " .. tostring(bn))
  for i = 1, an do
    assert(rawequal(a[i], b[i]), case .. ": result " .. i .. " is " .. tostring(a[i]) ..
        " against Lua's " .. tostring(b[i]))
  end
end

--- The counting `assert` answers every case as Lua's own does: the same
--- results, the same raised value, the same message and position. A Lua
--- upgrade that changes `luaB_assert` fails here rather than drifting.
local function test_it_answers_as_luas_own_assert_does()
  local value = {}
  local cases: {string: Packed} = {
    ["true"] = table.pack(true) as Packed,
    ["values"] = table.pack(1, "two", nil, 4) as Packed,
    ["false"] = table.pack(false) as Packed,
    ["nil"] = table.pack(nil) as Packed,
    ["no arguments"] = table.pack() as Packed,
    ["a message"] = table.pack(false, "m") as Packed,
    ["a message and more"] = table.pack(nil, "m", "extra", 3) as Packed,
    ["a format in the message"] = table.pack(false, "%d %s") as Packed,
    ["a number message"] = table.pack(false, 42) as Packed,
    ["a table message"] = table.pack(false, value) as Packed,
    ["a nil message and more"] = table.pack(false, nil, "x") as Packed,
  }
  local lua_assert = Assertions.lua_assert as function(...: any): any...
  for case, args in pairs(cases) do
    local n = args.n
    same(outcome(assert, table.unpack(args, 1, n)), outcome(lua_assert,
      table.unpack(args, 1, n)), case)
    same(tail_outcome(assert, table.unpack(args, 1, n)), tail_outcome(lua_assert,
      table.unpack(args, 1, n)), case .. " (tail call)")
  end
end
