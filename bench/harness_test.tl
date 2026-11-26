local Bench = require("bench.harness")

--- `n` samples: `value` each, the odd ones scaled by `spread`.
local function samples(n: integer, value: number, spread: number): {number}
  local out: mut {number} = {}
  for i = 1, n do out[i] = if i % 2 == 1 then value * spread else value end end
  return out
end

local function test_a_timing_keeps_the_samples_in_order_and_takes_the_fastest_and_the_median()
  local t = Bench.timing("x", 8, { 30, 10, 20, 40 })
  assert(t.best == 10 and t.median == 25 and t.n == 8)
  assert(t.samples[1] == 30 and t.samples[4] == 40)
  assert(Bench.timing("x", 1, { 3, 1, 2 }).median == 2)
end

local function test_a_compare_whose_band_is_below_one_is_faster()
  local c = Bench.compare(Bench.timing("x", 1, samples(20, 100, 1.1)), Bench.timing("x", 1, samples(20, 50, 1.1)))
  assert(c.verdict == "faster", c.verdict)
  assert(c.ratio == 0.5 and c.paired == 0.5 and c.low == 0.5 and c.high == 0.5)
end

local function test_a_compare_whose_band_is_above_one_is_slower()
  local c = Bench.compare(Bench.timing("x", 1, samples(20, 100, 1)), Bench.timing("x", 1, samples(20, 130, 1)))
  assert(c.verdict == "slower" and c.low > 1, c.verdict)
end

local function test_a_compare_whose_band_holds_one_is_the_same()
  -- New is faster in half the rounds and slower in the other half: the band spans 1.
  local old = Bench.timing("x", 1, samples(20, 100, 1))
  local new = Bench.timing("x", 1, samples(20, 90, 1.3))
  local c = Bench.compare(old, new)
  assert(c.verdict == "same" and c.low < 1 and c.high > 1, c.verdict)
  assert(c.ratio == 0.9)
end

local function test_a_compare_of_five_rounds_has_no_band()
  local ok, why = pcall(Bench.compare, Bench.timing("x", 1, samples(5, 1, 1)), Bench.timing("x", 1, samples(5, 1, 1)))
  assert(not ok and tostring(why):find("six rounds", 1, true) ~= nil, tostring(why))
end

local function test_a_suite_refuses_two_cases_of_one_name()
  local bench = Bench.new("t")
  bench.case("a", function(_: integer) end)
  local ok, why = pcall(bench.case, "a", function(_: integer) end)
  assert(not ok and tostring(why):find("two cases named a", 1, true) ~= nil, tostring(why))
end

local function test_a_word_that_names_no_case_is_refused_and_nothing_runs()
  local bench = Bench.new("t")
  local ran = false
  bench.case("json.decode", function(_: integer) ran = true end)
  assert(bench.main({ "jsno" }) == 2)
  assert(not ran)
end

local function test_a_selected_case_runs_its_setup_once_and_the_others_not_at_all()
  local bench = Bench.new("t")
  local setups: mut {string: integer} = {}
  local function counted(name: string): function()
    return function() setups[name] = (setups[name] or 0) + 1 end
  end
  local sink = 0
  local function body(n: integer)
    for i = 1, n do sink = sink + i end
  end
  bench.case("one", body, { setup = counted("one") })
  bench.case("two", body, { setup = counted("two") })
  assert(bench.main({ "--json", "--rounds", "2", "--target-ms", "1", "one" }) == 0)
  assert(setups["one"] == 1 and setups["two"] == nil and sink > 0)
end

local function test_a_body_that_ignores_its_n_is_refused_by_name()
  local bench = Bench.new("t")
  bench.case("idle", function(_: integer) end)
  local ok, why = pcall(bench.main, { "--rounds", "1", "--target-ms", "1" })
  assert(not ok and tostring(why):find("idle took under", 1, true) ~= nil, tostring(why))
end

local function test_compare_mode_needs_six_rounds()
  local bench = Bench.new("t")
  bench.case("one", function(_: integer) end)
  assert(bench.main({ "--against", "/nonexistent", "--rounds", "5" }) == 2)
end

local function test_binary_without_against_is_refused()
  local bench = Bench.new("t")
  bench.case("one", function(_: integer) end)
  assert(bench.main({ "--binary", "/nonexistent" }) == 2)
end

local function test_six_rounds_give_a_band_from_the_lowest_ratio_to_the_highest()
  local c = Bench.compare(Bench.timing("x", 1, { 10, 10, 10, 10, 10, 10 }),
    Bench.timing("x", 1, { 8, 9, 11, 7, 12, 10 }))
  assert(c.low == 0.7 and c.high == 1.2 and c.verdict == "same")
end

local function test_a_baseline_must_name_an_earlier_case()
  local bench = Bench.new("t")
  local ok, why = pcall(bench.case, "b", function(_: integer) end, { baseline = "a" })
  assert(not ok and tostring(why):find("baseline a is no earlier case", 1, true) ~= nil, tostring(why))
end
