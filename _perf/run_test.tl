local fs = require("cosmic.fs")
local run = require("_perf.run")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

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

-- An --only that matches zero scenarios used to exit 0 and write an
-- empty results file -- a comparison later would silently see nothing
-- rather than a mistyped filter. It must be an error now.
local function test_only_matching_nothing_errors()
  local code = run.main("--samples", "2", "--min-secs", "0.001",
    "--only", "zzz_no_such_scenario_xyz", "_perf.bench.json_bench")
  assert(code == 1, "--only matching nothing must error, got " .. code)
end
test_only_matching_nothing_errors()

-- The matching case must keep working: this is what confirms the fix
-- above checks the FILTERED count, not the total scenario count.
local function test_only_matching_something_still_succeeds()
  local code = run.main("--samples", "2", "--min-secs", "0.001",
    "--only", "json", "_perf.bench.json_bench")
  assert(code == 0, "a matching --only must still succeed, got " .. code)
end
test_only_matching_something_still_succeeds()

-- A module whose scenarios() call fails must abort the run exactly like
-- a module that fails to require() -- not skip past it and report on
-- whatever other modules happened to load. package.loaded is seeded
-- directly so this needs no on-disk fixture module.
local function test_scenarios_failure_aborts_before_later_modules()
  local later_called = false
  package.loaded["_perf.testdata.bad_scenarios_fixture"] = {
    scenarios = function(): {any}, string
      return nil, "boom"
    end,
    cleanup = function() end,
  }
  package.loaded["_perf.testdata.later_fixture"] = {
    scenarios = function(): {any}, string
      later_called = true
      return {}
    end,
    cleanup = function() end,
  }
  local code = run.main("--samples", "2", "--min-secs", "0.001",
    "_perf.testdata.bad_scenarios_fixture", "_perf.testdata.later_fixture")
  assert(code == 1, "a scenarios() failure must abort the run, got " .. code)
  assert(not later_called, "abort must happen before later modules run")
  package.loaded["_perf.testdata.bad_scenarios_fixture"] = nil
  package.loaded["_perf.testdata.later_fixture"] = nil
end
test_scenarios_failure_aborts_before_later_modules()

-- A typo'd module name anywhere in the list must fail BEFORE any
-- earlier module has spent its measurement time -- validation is a
-- separate pass, not interleaved with running.
local function test_bad_later_module_aborts_before_any_measurement()
  local ran = false
  package.loaded["_perf.testdata.good_fixture"] = {
    scenarios = function(): {any}, string
      ran = true
      return {}
    end,
  }
  local code = run.main("--samples", "1", "--min-secs", "0.001",
    "_perf.testdata.good_fixture", "_perf.no_such_module")
  assert(code == 1, "an unknown later module must fail the run, got " .. code)
  assert(not ran, "the failure must land before any module measures")
  package.loaded["_perf.testdata.good_fixture"] = nil
end
test_bad_later_module_aborts_before_any_measurement()

-- The --out parent directory is created up front: a fresh tree has no
-- o/perf, and failing the write at the END of a multi-minute run was
-- the most expensive possible way to learn that.
local function test_out_directory_is_created()
  package.loaded["_perf.testdata.tiny_fixture"] = {
    scenarios = function(): {any}, string
      return {
        {
          name = "tiny_noop",
          fn = function(_: any): any
            return 1
          end,
          check = function(_: any, _res: any): boolean, string
            return true
          end,
        },
      }
    end,
  }
  local out = fs.join(tmpdir, "made-dirs", "deep", "results.json")
  local code = run.main("--samples", "1", "--min-secs", "0.001",
    "--out", out, "_perf.testdata.tiny_fixture")
  assert(code == 0, "run with a fresh --out directory must pass, got " .. code)
  assert(fs.is_file(out), "results file must land in the created directory")
  package.loaded["_perf.testdata.tiny_fixture"] = nil
end
test_out_directory_is_created()

-- With no modules named, discovery finds every _perf/bench module --
-- the BENCH=$(ls ...) incantation the docs used to carry, done by the
-- runner itself.
local function test_discovery_lists_bench_modules()
  local names, derr = run.discover_benches()
  assert(names ~= nil, "discovery must find bench modules: " .. tostring(derr))
  local seen = false
  for _, name in ipairs(names) do
    if name == "_perf.bench.json_bench" then
      seen = true
    end
  end
  assert(seen, "discovery must name _perf.bench.json_bench")
end
test_discovery_lists_bench_modules()

print("OK run_test")
