local Bench = require("cosmic.bench")
local Json = require("cosmic.json")

--- `n` samples: `value` each, the odd ones scaled by `spread`.
local function samples(n: integer, value: number, spread: number): {number}
  local out: mut {number} = {}
  for i = 1, n do out[i] = if i % 2 == 1 then value * spread else value end end
  return out
end

local function test_a_timing_keeps_the_samples_in_order_and_takes_the_fastest_and_the_median()
  local t = Bench.timing("x", 8, { 30, 10, 20, 40 })
  assert(t.best == 10 and t.median == 25 and t.n == 8 and t.bytes == 0)
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
  local c = Bench.compare(Bench.timing("x", 1, samples(20, 100, 1)), Bench.timing("x", 1, samples(20, 90, 1.3)))
  assert(c.verdict == "same" and c.low < 1 and c.high > 1, c.verdict)
  assert(c.ratio == 0.9)
end

local function test_a_compare_of_five_rounds_has_no_band()
  local ok, why = pcall(Bench.compare, Bench.timing("x", 1, samples(5, 1, 1)), Bench.timing("x", 1, samples(5, 1, 1)))
  assert(not ok and tostring(why):find("six rounds", 1, true) ~= nil, tostring(why))
end

local function test_a_line_says_the_fastest_the_median_the_size_and_a_rate_where_it_reads_bytes()
  local line = Bench.line(Bench.timing("decode", 64, { 2000, 1000, 3000 }, 500), 8)
  assert(line == "decode           1000 ns/op  (median 2000, n=64)  0.500 GB/s", line)
  assert(Bench.line(Bench.timing("idle", 1, { 1.5 })):find("1.50 ns/op", 1, true) ~= nil)
end

local function test_a_record_is_one_line_of_json_with_every_sample()
  local text = Bench.record(Bench.timing("decode", 64, { 2000, 1000 }, 500))
  assert(text:find("\n", 1, true) == nil, text)
  local value = assert(Json.decode_object(text))
  assert(value["name"] == "decode" and value["unit"] == "ns/op" and value["best"] == 1000 and value["median"] == 1500, text)
  assert(value["n"] == 64 and value["rounds"] == 2 and value["bytes"] == 500 and value["gb_per_s"] == 0.5, text)
  local without = assert(Json.decode_object(Bench.record(Bench.timing("idle", 1, { 1 }))))
  assert(without["bytes"] == nil and without["gb_per_s"] == nil)
end

--- A bench of the statistics themselves: a plain run calls it once, and `cosmic test --bench` times it.
local function bench_timing_of_twenty_samples(b: Bench.B)
  local twenty = samples(20, 100, 1.1)
  b.reset()
  for _ = 1, b.n do Bench.timing("x", 1, twenty) end
end

local function test_a_bench_is_handed_one_operation_and_a_directory_in_a_plain_run()
  -- This test file's own bench runs as a test too; here its body is called as the runner calls it.
  local reset = false
  local b: Bench.B = { n = 1, bytes = 0, dir = ".", reset = function() reset = true end }
  bench_timing_of_twenty_samples(b)
  assert(reset)
end

local function test_a_compared_line_names_both_bests_the_ratios_the_band_and_the_verdict()
  local c = Bench.compare(Bench.timing("x", 1, samples(20, 100, 1.1)), Bench.timing("x", 1, samples(20, 50, 1.1)))
  local line = Bench.compared_line(c, 4)
  assert(line:sub(1, 5) == "x    ", line)
  assert(line:find("100", 1, true) and line:find("50.0", 1, true) and line:find("[0.500, 0.500]", 1, true), line)
  assert(line:sub(-6) == "faster", line)
  assert(Bench.compared_header(20, 4):find("best of 20", 1, true) ~= nil)
end

local function test_a_compared_record_holds_each_side_with_its_binary()
  local c = Bench.compare(Bench.timing("x", 4, samples(6, 100, 1)), Bench.timing("x", 8, samples(6, 130, 1)))
  local text = Bench.compared_record(c, "/old", "/new")
  assert(text:find("\n", 1, true) == nil, text)
  local value = assert(Json.decode_object(text))
  assert(value["name"] == "x" and value["rounds"] == 6 and value["verdict"] == "slower", text)
  local old, new = Json.object_of(value["old"])!, Json.object_of(value["new"])!
  assert(old["binary"] == "/old" and old["n"] == 4 and new["binary"] == "/new" and new["n"] == 8, text)
end
