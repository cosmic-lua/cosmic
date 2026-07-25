local run = require("_perf.run")

local function test_parse_defaults()
  local a = run.parse_args({"_perf.bench.json_bench"})
  assert(a.err == nil, "unexpected parse error: " .. tostring(a.err))
  assert(a.samples == 5, "default samples wrong: " .. tostring(a.samples))
  assert(a.min_secs > 0, "default min_secs missing")
  assert(not a.compare_mode, "compare mode should default off")
  assert(#a.positional == 1 and a.positional[1] == "_perf.bench.json_bench",
    "positional args wrong")
end
test_parse_defaults()

local function test_parse_run_flags()
  local a = run.parse_args({
      "--out", "results.json",
      "--samples", "3",
      "--min-secs", "0.05",
      "--only", "json",
      "_perf.bench.json_bench",
    })
  assert(a.err == nil, "unexpected parse error: " .. tostring(a.err))
  assert(a.out == "results.json", "out wrong")
  assert(a.samples == 3, "samples wrong")
  assert(math.abs(a.min_secs - 0.05) < 1e-9, "min_secs wrong")
  assert(a.only == "json", "only wrong")
end
test_parse_run_flags()

local function test_parse_compare_flags()
  local a = run.parse_args({"--compare", "--threshold", "5", "base.json", "cur.json"})
  assert(a.err == nil, "unexpected parse error: " .. tostring(a.err))
  assert(a.compare_mode, "compare mode not set")
  assert(math.abs(a.threshold - 5.0) < 1e-9, "threshold wrong")
  assert(#a.positional == 2, "positional count wrong")
end
test_parse_compare_flags()

local function test_parse_rejects_bad_values()
  assert(run.parse_args({"--samples", "zero"}).err ~= nil, "bad samples accepted")
  assert(run.parse_args({"--samples", "0"}).err ~= nil, "zero samples accepted")
  assert(run.parse_args({"--min-secs", "-1"}).err ~= nil, "negative min-secs accepted")
  assert(run.parse_args({"--threshold", "nope"}).err ~= nil, "bad threshold accepted")
end
test_parse_rejects_bad_values()

local function test_collect_meta()
  local meta = run.collect_meta(3, 0.05)
  assert(meta.samples == 3, "meta samples wrong")
  assert(math.abs(meta.min_sample_secs - 0.05) < 1e-9, "meta min_secs wrong")
  assert(meta.timestamp ~= nil and meta.timestamp > 0, "meta timestamp missing")
  assert(meta.os ~= nil and #meta.os > 0, "meta os missing")
  assert(meta.bin ~= nil and #meta.bin > 0, "meta bin missing")
end
test_collect_meta()

local function test_load_module_validates()
  local mod, err = run.load_module("_perf.bench.json_bench")
  assert(mod ~= nil, "bench module should load: " .. tostring(err))
  local bad, berr = run.load_module("_perf.stats")
  assert(bad == nil and berr ~= nil and berr:find("scenarios", 1, true),
    "non-bench module should be rejected: " .. tostring(berr))
  local missing, merr = run.load_module("_perf.no_such_module")
  assert(missing == nil and merr ~= nil, "missing module should error")
end
test_load_module_validates()

print("OK run_test")
