--- The speed of [`Json.to_value`] for tables that are shared, held to a ratio and never to a clock: four times the
--- input costs about four times the time. A table reached by several ways at several depths is copied once, so a
--- ladder whose every rung holds the one below it bare and wrapped in one to four singleton tables is linear in its
--- rungs; copying a table again for each depth it is met at would not be.
local Json = require("cosmic.json")
local Speed = require("lang.speed")
local Test = require("cosmic.test")

Test.policy{}

--- `leaf` inside `levels` arrays.
local function wrapped(leaf: Json.Value, levels: integer): Json.Value
  local out = leaf
  for _ = 1, levels do
    out = { out }
  end
  return out
end

--- A ladder of `rungs` rungs: each holds the one below it, and that rung inside one to four arrays.
local function ladder(rungs: integer): Json.Value
  local rung: Json.Value = { 1 }
  for _ = 1, rungs do
    rung = { rung, wrapped(rung, 1), wrapped(rung, 2), wrapped(rung, 3), wrapped(rung, 4) }
  end
  return rung
end

local function test_to_value_of_a_shared_ladder_is_linear()
  local small, large = ladder(10), ladder(40)
  local ok, why = Speed.within(function()
    assert(Json.to_value(small))
  end, function()
    assert(Json.to_value(large))
  end, 8)
  assert(ok, "four times the rungs cost more than eight times the time: " .. why)
end
