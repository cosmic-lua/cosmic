local Child = require("cosmic.child")
local PinTime = require("cosmic_ci.pin_time")
local Time = require("cosmic.time")

--- A wait of 1500 ms is the count the running release reads as that.
local function test_a_wait_is_in_the_units_of_the_release_that_runs_it()
  local tree = (Time as any as {string:function(integer): integer}).ms
  local want = tree ~= nil and tree(1500) or 1500
  assert(PinTime.wait(1500) == want, tostring(PinTime.wait(1500)))
end

--- A timeout set through `options` ends a child at the time it names,
--- whichever release runs it: 300 ms into a child that sleeps for 30 s.
local function test_a_timeout_ends_a_child_when_it_says()
  local before = Time.monotonic_ns()
  local result = assert(Child.run({ "/bin/sh", "-c", "sleep 30" },
    PinTime.options({ stdout = "capture", stderr = "capture" }, 300)))
  local took = Time.monotonic_ns() - before
  assert(result.timed_out, "the child was not ended for its timeout")
  assert(took < 10 * 1000 * 1000 * 1000, "the timeout took " .. took // 1000000 .. " ms")
end

local function test_no_timeout_sets_no_field()
  local options = PinTime.options({}, nil) as any as {string:integer}
  assert(options.timeout_ms == nil and options.timeout_ns == nil)
end
