--- [`lang.speed`] passes work that costs its multiple and refuses work that costs
--- a quadratic more, whatever a moment of load does to one side.
local Speed = require("lang.speed")
local Test = require("cosmic.test")

Test.policy{}

--- Work that costs about `n` steps.
local function linear(n: integer): function()
  return function()
    local sum = 0
    for i = 1, n do
      sum = sum + i % 7
    end
    assert(sum >= 0)
  end
end

--- Work that costs about `n` squared steps.
local function quadratic(n: integer): function()
  return function()
    local sum = 0
    for i = 1, n do
      for j = 1, n do
        sum = sum + (i + j) % 7
      end
    end
    assert(sum >= 0)
  end
end

local function test_four_times_the_linear_work_is_within_ten_times()
  local ok, why = Speed.within(linear(2000), linear(8000), 10)
  assert(ok, why)
end

local function test_eight_times_the_input_of_a_quadratic_form_is_over_ten_times()
  -- 64 times the steps: a slow moment on the small side in one pair of samples does not bring it under ten.
  local ok, why = Speed.within(quadratic(50), quadratic(400), 10)
  assert(not ok and why:find("over 10 times", 1, true) ~= nil, why)
end

local function test_a_sample_of_work_that_takes_almost_no_time_is_still_read()
  assert(Speed.least(function() end) >= 0)
  assert(Speed.least(linear(10)) > 0)
end
