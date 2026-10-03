--- Paired, warm-cache artifact measurements, controlled by a fixed Cosmic.
---
--- `bin/perf <baseline> <candidate> <new-output-directory> [pairs] [workload]` keeps
--- executable copies, fixtures, commands, outputs and nanosecond observations.
--- It first measures the baseline against itself, then alternates A/B and B/A.
--- The sample count is fixed before observing any results; no adaptive repeat.
--- Run with no other builds or benchmarks on the host. This does not control
--- the OS page cache, measure peak RSS, or replace target/sandbox correctness CI.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Clock = require("cosmic.clock")

local sys = require("cosmic.sys")

local record Perf
  record Interval
    low: number | nil
    high: number | nil
    lower_bounded: boolean
    upper_bounded: boolean
  end
  record Distribution
    median: number
    p95: number
    low: number
    high: number
    p95_interval: Interval
  end
  record Pair
    a: number
    b: number
  end
end

local rank_cache: {string:{integer}} = {}

--- Relative binomial masses start at the mode, avoiding the underflow of
--- p^n at large n. Each outward recurrence decreases; normalizing their sum
--- gives both tails without subtracting a tiny probability from one.
local function ranks(n: integer, numerator: integer, denominator: integer,
                     tail_denominator: integer): integer, integer
  local key = n .. ":" .. numerator .. ":" .. denominator .. ":" .. tail_denominator
  local cached = rank_cache[key]
  if cached ~= nil then return cached[1], cached[2] end
  local mode = ((n + 1) * numerator) // denominator
  local weights: {number} = {}
  weights[mode + 1] = 1
  for k = mode, 1, -1 do
    weights[k] = weights[k + 1] * k * (denominator - numerator) /
      ((n - k + 1) * numerator)
  end
  for k = mode, n - 1 do
    weights[k + 2] = weights[k + 1] * (n - k) * numerator /
      ((k + 1) * (denominator - numerator))
  end
  local total = 0.0
  for _, weight in ipairs(weights) do total = total + weight end
  local limit = total / tail_denominator
  local cumulative, lower, upper = 0.0, 0, n + 1
  for k = 0, n do
    cumulative = cumulative + weights[k + 1]
    if cumulative > limit then break end
    lower = k + 1
  end
  cumulative = 0
  for k = n, 0, -1 do
    cumulative = cumulative + weights[k + 1]
    if cumulative > limit then break end
    upper = k
  end
  rank_cache[key] = { lower, upper }
  return lower, upper
end

local function interval(low: number | nil, high: number | nil): Perf.Interval
  assert(low == nil or (low == low and math.abs(low) < math.huge), "lower bound is not finite")
  assert(high == nil or (high == high and math.abs(high) < math.huge), "upper bound is not finite")
  return { low = low, high = high, lower_bounded = low ~= nil, upper_bounded = high ~= nil }
end

--- Median with a 95% sign interval, and p95 with a 97.5% order-statistic
--- interval. The latter gives a joint 95% difference bound for two samples
--- by Bonferroni, even when observations within each pair are dependent.
function Perf.distribution(values: {number}): Perf.Distribution
  assert(#values >= 6, "at least six observations for a 95% median interval")
  local sorted: {number} = {}
  for _, value in ipairs(values) do
    assert(value == value and math.abs(value) < math.huge, "observations must be finite")
    sorted[#sorted + 1] = value
  end
  table.sort(sorted)
  local n = #sorted
  local middle = (n + 1) // 2
  local median = sorted[middle]
  if n % 2 == 0 then median = median / 2 + sorted[middle + 1] / 2 end
  local lower, upper = ranks(n, 1, 2, 40)
  local tail_lower, tail_upper = ranks(n, 19, 20, 80)
  return { median = median, p95 = sorted[math.ceil(n * 0.95)],
    low = sorted[lower], high = sorted[upper],
    p95_interval = interval(sorted[tail_lower], sorted[tail_upper]) }
end

local record Reading
  a: Perf.Distribution
  b: Perf.Distribution
  delta: Perf.Distribution
  noise: number
  calibration: Perf.Distribution
  calibration_deviation: Perf.Distribution
  candidate_deviation: Perf.Distribution
  tail_delta: number
  tail_interval: Perf.Interval
  calibration_tail_delta: number
  calibration_tail_interval: Perf.Interval
  tail_noise: number | nil
  sample_count: integer
  calibration_count: integer
  status: string
  reasons: {string}
end

local function deviations(values: {number}, median: number): Perf.Distribution
  local out: {number} = {}
  for _, value in ipairs(values) do out[#out + 1] = math.abs(value - median) end
  return Perf.distribution(out)
end

local function difference(a: Perf.Interval, b: Perf.Interval): Perf.Interval
  local al, ah, bl, bh = a.low, a.high, b.low, b.high
  local low, high: number | nil, number | nil
  if bl ~= nil and ah ~= nil then low = bl - ah end
  if bh ~= nil and al ~= nil then high = bh - al end
  return interval(low, high)
end

local function radius(bounds: Perf.Interval): number | nil
  local low, high = bounds.low, bounds.high
  if low == nil or high == nil then return nil end
  return math.max(math.abs(low), math.abs(high))
end

--- A fixed-sample screen for detected slowdown, not an equivalence test.
--- A wholly positive median or tail interval cannot pass; each statistic's
--- own A/A uncertainty distinguishes regression from unresolved evidence.
function Perf.compare(calibration: {Perf.Pair}, samples: {Perf.Pair}): Reading
  local noise, a, b, deltas: {number}, {number}, {number}, {number} = {}, {}, {}, {}
  local ca, cb: {number}, {number} = {}, {}
  for _, pair in ipairs(calibration) do
    noise[#noise + 1], ca[#ca + 1], cb[#cb + 1] = pair.b - pair.a, pair.a, pair.b
  end
  for _, pair in ipairs(samples) do
    a[#a + 1], b[#b + 1] = pair.a, pair.b
    deltas[#deltas + 1] = pair.b - pair.a
  end
  local calibrated = Perf.distribution(noise)
  local resolution = math.max(math.abs(calibrated.low), math.abs(calibrated.high))
  local left, right, delta = Perf.distribution(a), Perf.distribution(b), Perf.distribution(deltas)
  local cleft, cright = Perf.distribution(ca), Perf.distribution(cb)
  local tail = difference(left.p95_interval, right.p95_interval)
  local ctail = difference(cleft.p95_interval, cright.p95_interval)
  local tail_resolution = radius(ctail)
  local calibration_deviation = deviations(noise, calibrated.median)
  local candidate_deviation = deviations(deltas, delta.median)
  local reasons: {string} = {}
  local median_unbiased = calibrated.low <= 0 and calibrated.high >= 0
  local ctl, cth, tl, th = ctail.low, ctail.high, tail.low, tail.high
  local tail_unbiased = ctl ~= nil and cth ~= nil and ctl <= 0 and cth >= 0
  local enough = #samples >= 200 and #calibration >= 200
  if not enough then reasons[#reasons + 1] = "exploratory_sample_count" end
  if tl == nil or th == nil or tail_resolution == nil then
    reasons[#reasons + 1] = "unbounded_tail_interval"
  end
  if not median_unbiased then reasons[#reasons + 1] = "biased_median_calibration" end
  if not tail_unbiased then reasons[#reasons + 1] = "biased_tail_calibration" end
  if delta.low > 0 then reasons[#reasons + 1] = "positive_median_interval" end
  if tl ~= nil and tl > 0 then reasons[#reasons + 1] = "positive_tail_interval" end
  -- Centered deviations share an estimated center: this remains a heuristic
  -- noise veto, not a confidence interval for population dispersion.
  if candidate_deviation.low > calibration_deviation.high then
    reasons[#reasons + 1] = "increased_dispersion"
  end
  local status = #reasons == 0 and "pass" or "inconclusive"
  if enough and ((median_unbiased and delta.low > resolution) or
      (tail_unbiased and tl ~= nil and tail_resolution ~= nil and tl > tail_resolution)) then
    status = "regression"
  end
  return { a = left, b = right, delta = delta, noise = resolution,
    calibration = calibrated, calibration_deviation = calibration_deviation,
    candidate_deviation = candidate_deviation, tail_delta = right.p95 - left.p95,
    tail_interval = tail, calibration_tail_delta = cright.p95 - cleft.p95,
    calibration_tail_interval = ctail, tail_noise = tail_resolution,
    sample_count = #samples, calibration_count = #calibration, status = status, reasons = reasons }
end

--- Require equal logical build histories, including discarded warmups. Physical
--- pages and timings are deliberately not part of this state comparison.
function Perf.check_history(a: {string}, b: {string})
  assert(#a == 6 and #b == 6, "missing build history counters")
  assert(a[5] == b[5] and a[6] == b[6], "unbalanced fixture build history")
end

--- Check the exact effect of a command outside its timed region. Reads and
--- compilation belong only to the deliberate leaf mutation workload.
function Perf.check_transition(before: {string}, after: {string}, builds: boolean, change: boolean)
  assert(#before == 6 and #after == 6, "missing build history counters")
  local delta = builds and 1 or 0
  assert(tonumber(after[5]) == tonumber(before[5]) + delta and
      tonumber(after[6]) == tonumber(before[6]) + delta, "unexpected build history transition")
  assert(after[4] == "PASS", "fixture build failed")
  if builds then
    assert(tonumber(after[1]) + tonumber(after[2]) == 6, "build lost fixture modules")
    if change then
      assert(tonumber(after[1]) > 0 and tonumber(after[3]) > 0, "leaf edit read/compiled no modules")
    else
      assert(after[1] == "0" and after[2] == "6" and after[3] == "0", "no-op read/compiled modules")
    end
  else
    for i = 1, 6 do assert(before[i] == after[i], "non-building command changed build counters") end
  end
end

local record Fixture
  binary: string
  root: string
  host: string
  portable: string
  host_tool: string
  logs: string
  env: {string:string}
end

local record Workload
  name: string
  args: {string}
  batch: integer
  executable: string
  change: boolean
  builds: boolean
  ran: integer
  stood: integer
end

local record Observation
  phase: string
  workload: string
  pair: integer
  label: string
  elapsed_ns: integer
  batch: integer
  argv: {string}
  cwd: string
  stdout: string
  stderr: string
  before: {string}
  after: {string}
  leaf_value: integer
end

local function json_bounds(value: any): any
  if not value is {any:any} then return value end
  local copy: {any:any} = {}
  for key, item in pairs(value) do copy[key] = json_bounds(item) end
  if value.lower_bounded == false then copy.low = Json.null end
  if value.upper_bounded == false then copy.high = Json.null end
  if value.calibration_tail_interval ~= nil and value.tail_noise == nil then
    copy.tail_noise = Json.null
  end
  return copy
end

local function save(path: string, value: any)
  assert(Fs.write(path, assert(Json.encode(value, { pretty = true })) .. "\n"))
end

local function command(argv: {string}, fixture: Fixture): Child.Result
  local result, trouble = Child.run(argv, { cwd = fixture.root, env = fixture.env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  if result == nil then
    save(fixture.logs .. "/failure.json", { argv = argv, trouble = trouble })
    error(trouble)
  end
  if not result.ok or result.truncated then
    save(fixture.logs .. "/failure.json", { argv = argv, result = result })
    error(table.concat(argv, " ") .. ": " .. (result.stderr or "") .. (result.stdout or ""))
  end
  return result
end

local function leaf(fixture: Fixture, value: integer)
  assert(Fs.write(fixture.root .. "/leaf.tl", "local record Leaf end\n" ..
      "function Leaf.value(): integer return " .. value .. " end\nreturn Leaf\n"))
  assert(Fs.set_mtime(fixture.root .. "/leaf.tl", 1000000000, value))
end

local function latest_build(fixture: Fixture): {string}
  local db = assert(Sqlite.open(fixture.root .. "/o/build.db"))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT compiled, cached, read, verdict, run, (SELECT COUNT(*) FROM builds) FROM builds ORDER BY run DESC LIMIT 1"))
  assert(db:close())
  assert(#rows == 1 and rows[1][4] == "PASS", "missing successful build counters")
  return rows[1]
end

local function fixture(binary: string, root: string): Fixture
  assert(Fs.mkdirs(root .. "/cmd/noop"))
  assert(Fs.mkdirs(root .. "/o/perf"))
  local env = Env.all()
  for name in pairs(env) do
    if name:sub(1, 7) == "COSMIC_" then env[name] = nil end
  end
  env.COSMIC_AUTO_BOOT = "0"
  env.COSMIC_BUILD_CACHE = "0"
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_PORTABLE_CACHE = root .. "/o/portable-cache"
  local f: Fixture = { binary = binary, root = root, host = root .. "/host",
    portable = root .. "/portable", host_tool = root .. "/host-tool",
    logs = root .. "/o/perf", env = env }
  leaf(f, 1)
  assert(Fs.write(root .. "/branch.tl", [[local Leaf = require("leaf")
local record Branch end
function Branch.value(): integer return Leaf.value() end
return Branch
]]))
  assert(Fs.write(root .. "/spare.tl", [[local record Spare end
function Spare.value(): integer return 7 end
return Spare
]]))
  assert(Fs.write(root .. "/branch_test.tl", [[local Branch = require("branch")
local function test_value() assert(Branch.value() > 0) end
]]))
  assert(Fs.write(root .. "/spare_test.tl", [[local Spare = require("spare")
local function test_value() assert(Spare.value() == 7) end
]]))
  assert(Fs.write(root .. "/cmd/noop/main.tl", [[local Branch = require("branch")
local Spare = require("spare")
return function(_argv: {string}): integer
  assert(Branch.value() > 0 and Spare.value() == 7)
  return 0
end
]]))
  -- Stage can trust these old, explicitly different timestamps immediately;
  -- no-op samples must not include its two-second freshly-written-file path.
  for _, path in ipairs({ "branch.tl", "spare.tl", "branch_test.tl", "spare_test.tl", "cmd/noop/main.tl" }) do
    assert(Fs.set_mtime(root .. "/" .. path, 1000000000))
  end
  local setup: {Child.Result} = {}
  setup[#setup + 1] = command({ binary, "build", "--host" }, f)
  assert(Fs.write(f.host, assert(Fs.read(root .. "/o/bin/noop")), 493))
  setup[#setup + 1] = command({ binary, "build" }, f)
  assert(Fs.write(f.portable, assert(Fs.read(root .. "/o/bin/noop")), 493))
  setup[#setup + 1] = command({ binary, "test" }, f)
  setup[#setup + 1] = command({ binary, "test" }, f)
  -- Produce a native tool from its own trusted core, preserving its database.
  -- This is setup, not part of a startup timing.
  local source = "local A=require('build.artifact'); local F=require('cosmic.fs'); " ..
    "local p=assert(A.split(assert(F.read(" .. Json.quote(binary) .. ")))); " ..
    "assert(F.write(" .. Json.quote(f.host_tool) ..
    ",assert(A.host_program(assert(A.trusted_core()),p.database)),493))"
  setup[#setup + 1] = command({ binary, "-e", source }, f)
  save(f.logs .. "/setup.json", setup)
  local facts = [[local A=require('build.artifact'); local J=require('cosmic.json');
local H=require('cosmic.hash'); local S=require('cosmic.store');
local c=assert(A.trusted_core()); print(assert(J.encode({
  sqlite=require('cosmic.sqlite').version, core_sha256=H.hex_sha256(c.bytes),
  target=c.target_id, configuration=c.configuration_id,
  runtime_basis=S.meta('runtime_basis'), boot_hash=S.meta('boot_hash')})))]]
  local information = command({ binary, "-e", facts }, f)
  assert(Fs.write(f.logs .. "/runtime.json", information.stdout or ""))
  local compiler = command({ binary, "sql", "--store",
    "SELECT key,CAST(value AS TEXT) AS identity FROM meta WHERE key IN ('compiler','compiled_by') ORDER BY key" }, f)
  assert(Fs.write(f.logs .. "/compiler.tsv", compiler.stdout or ""))
  local plans = command({ binary, "sql", "--store",
    "EXPLAIN QUERY PLAN SELECT path FROM imports WHERE requires='cosmic.sqlite'" }, f)
  assert(Fs.write(f.logs .. "/query-plan.txt", (plans.stdout or "") .. (plans.stderr or "")))
  return f
end

local function workloads(): {Workload}
  return {
    { name = "portable_startup", args = {}, batch = 5, executable = "portable" },
    { name = "host_startup", args = {}, batch = 5, executable = "host" },
    { name = "tool_startup", args = { "-e", "" }, batch = 5 },
    { name = "native_tool_startup", args = { "-e", "" }, batch = 5, executable = "host_tool" },
    { name = "first_require", args = { "-e", "assert(require('cosmic.sqlite'))" }, batch = 5 },
    { name = "require_closure", args = { "-e", "assert(require('cosmic.sqlite')); " ..
        "assert(require('cosmic.json')); assert(require('cosmic.child'))" }, batch = 5 },
    { name = "exact_docs", builds = true, args = { "docs", "Fs.read" }, batch = 1 },
    { name = "uses", builds = true, args = { "uses", "Fs.read" }, batch = 1 },
    { name = "reverse_imports", args = { "sql", "--store",
      "SELECT path FROM imports WHERE requires='cosmic.sqlite' ORDER BY path" }, batch = 1 },
    { name = "outgoing_uses", args = { "sql", "--store",
      "SELECT module,symbol,line FROM uses WHERE from_module='cosmic.sqlite' ORDER BY module,symbol,line" }, batch = 1 },
    { name = "embed_portable", builds = true, args = { "build" }, batch = 1 },
    { name = "embed_host", builds = true, args = { "build", "--host" }, batch = 1 },
    { name = "noop_test", builds = true, args = { "test" }, batch = 1, ran = 0, stood = 2 },
    { name = "full_fixture_test", builds = true, args = { "test" }, batch = 1, ran = 2, stood = 0 },
    { name = "leaf_edit_test", builds = true, args = { "test" }, batch = 1, change = true, ran = 1, stood = 1 },
  }
end

local function measure(f: Fixture, w: Workload, phase: string, pair: integer,
                       label: string, leaf_value: integer): Observation
  local executable = f.binary
  if w.executable == "portable" then
    executable = f.portable
  elseif w.executable == "host" then
    executable = f.host
  elseif w.executable == "host_tool" then
    executable = f.host_tool
  end
  local argv = { executable }
  for _, word in ipairs(w.args) do argv[#argv + 1] = word end
  if w.change then
    -- Both phases see the same new content, never an earlier verdict.
    leaf(f, leaf_value)
  end
  if w.name == "full_fixture_test" then
    local db = assert(Sqlite.open(f.root .. "/o/build.db", { writable = true }))
    assert(db:exec("DELETE FROM verdicts"))
    assert(db:close())
  end
  local before = latest_build(f)
  local result: Child.Result
  local start = Clock.monotonic_ns()
  for _ = 1, w.batch do result = command(argv, f) end
  local elapsed = Clock.monotonic_ns() - start
  local stdout, stderr = result.stdout or "", result.stderr or ""
  local observation: Observation = { phase = phase, workload = w.name, pair = pair, label = label,
    elapsed_ns = elapsed, batch = w.batch, argv = argv, cwd = f.root,
    stdout = stdout, stderr = stderr, before = before, after = latest_build(f) }
  if w.change then observation.leaf_value = leaf_value end
  save(f.logs .. "/current.json", observation)
  if w.name == "exact_docs" then
    assert(stdout:find("Fs.read", 1, true), "docs did not return Fs.read")
  elseif w.name == "uses" then
    assert(stdout:find("cosmic/", 1, true) and stdout:find(".tl:", 1, true), "uses returned no locations")
  elseif w.name == "reverse_imports" then
    assert(stdout:find("cosmic.store", 1, true), "reverse imports omitted cosmic.store")
  elseif w.name == "outgoing_uses" then
    assert(stdout:find("cosmic.", 1, true), "outgoing uses returned no symbols")
  elseif w.name:find("startup", 1, true) or w.name:find("require", 1, true) then
    assert(stdout == "" and stderr == "", "startup/require unexpectedly produced output")
  end
  if w.ran ~= nil then
    local ran, stood = (stdout .. stderr):match("; (%d+) ran, (%d+) stood")
    assert(tonumber(ran) == w.ran and tonumber(stood) == w.stood,
      w.name .. ": unexpected test counters: " .. stdout .. stderr)
    assert(not (stdout .. stderr):find("test: SKIP", 1, true), "fixture skipped a test")
  end
  Perf.check_transition(before, observation.after, w.builds, w.change)
  save(f.logs .. "/counters.json", { before = before, after = observation.after })
  return observation
end

local function run_pairs(a: Fixture, b: Fixture, w: Workload, phase: string,
                         count: integer, raw: {Observation}, offset: integer, mutation_offset: integer): {Perf.Pair}
  local paired: {Perf.Pair} = {}
  local observations: {Observation} = {}
  -- Three discarded warmups follow exactly the same preparation and checks.
  for i = 1, count + 3 do
    local first, second: Observation, Observation
    if i % 2 == 1 then
      first = measure(a, w, phase, offset + i, "a", mutation_offset + i)
      second = measure(b, w, phase, offset + i, "b", mutation_offset + i)
    else
      second = measure(b, w, phase, offset + i, "b", mutation_offset + i)
      first = measure(a, w, phase, offset + i, "a", mutation_offset + i)
    end
    observations[#observations + 1], observations[#observations + 2] = first, second
    save(a.logs .. "/" .. phase .. "-" .. w.name .. ".json", observations)
    Perf.check_history(first.before, second.before)
    Perf.check_history(first.after, second.after)
    if i > 3 then
      raw[#raw + 1], raw[#raw + 2] = first, second
      paired[#paired + 1] = { a = first.elapsed_ns / w.batch, b = second.elapsed_ns / w.batch }
    end
  end
  return paired
end

--- Run independently retained artifacts in new fixture directories. Status 1
--- means a command/counter failed; status 2 means a measured regression or an
--- unresolved comparison. Neither is a passing performance gate.
function Perf.main(argv: {integer:string}): integer
  if argv[1] == nil or argv[2] == nil or argv[3] == nil or argv[6] ~= nil then
    print("usage: bin/perf <baseline> <candidate> <new-output-directory> [pairs=200] [workload]")
    return 1
  end
  local count: integer = 200
  if argv[4] ~= nil then
    local parsed = tonumber(argv[4])
    assert(parsed ~= nil, "pairs must be a number")
    count = math.tointeger(parsed)
  end
  assert(count ~= nil and count >= 30 and count <= 2000, "pairs must be an integer from 30 to 2000")
  local selected: {Workload} = {}
  for _, w in ipairs(workloads()) do
    if argv[5] == nil or argv[5] == w.name then selected[#selected + 1] = w end
  end
  assert(#selected > 0, "unknown workload: " .. (argv[5] or ""))
  local output = argv[3]
  local exists, exists_trouble = Fs.exists(output)
  assert(exists ~= nil, exists_trouble)
  assert(not exists, "output directory must not already exist")
  assert(Fs.mkdirs(output))
  output = assert(Fs.absolute(output))
  local binaries: {string} = {}
  local artifacts: {any} = {}
  local cpuinfo, _ = Fs.read("/proc/cpuinfo")
  local kernel, _ = Fs.read("/proc/version")
  local controller = assert(Proc.executable())
  local script = assert(Fs.absolute(argv[0]))
  local pin_path = script:gsub("/build/perf.tl$", "/ci/cosmic-driver.pin")
  local pin, _ = Fs.read(pin_path)
  local timer: {number} = {}
  for _ = 1, 100 do
    local start = Clock.monotonic_ns()
    timer[#timer + 1] = Clock.monotonic_ns() - start
  end
  local metadata: {string:any} = { cache = "warm OS page cache, fresh process per command",
    sandbox = "unsandboxed fixtures; no shared compile or verdict cache",
    cold_io = "unmeasured", peak_rss = "unmeasured", pairs = count,
    protocol = "fixed-sample-v3", adaptive_repeat = false, exploratory = count < 200,
    host = assert(sys.uname()), cpu_features = sys.cpu_features(),
    controller_sqlite = Sqlite.version, cpuinfo = cpuinfo,
    kernel = kernel, artifacts = artifacts,
    controller = { path = controller, sha256 = Hash.hex_sha256((assert(Fs.read(controller)))), pin = pin },
    script_sha256 = Hash.hex_sha256((assert(Fs.read(script)))),
    workload = argv[5] or "all",
    timer_overhead_ns = Perf.distribution(timer),
    baseline_commit = Env.get("COSMIC_PERF_BASELINE_COMMIT"),
    candidate_commit = Env.get("COSMIC_PERF_CANDIDATE_COMMIT") }
  for i = 1, 2 do
    local input = assert(Fs.absolute(argv[i]))
    local bytes = assert(Fs.read(input))
    local retained = output .. "/artifact-" .. i
    assert(Fs.write(retained, bytes, 493))
    binaries[i] = retained
    artifacts[i] = { input = input, retained = retained, sha256 = Hash.hex_sha256(bytes), bytes = #bytes }
  end
  local manifest = {
    { id = "aa-a", phase = "aa", label = "a", artifact_index = 1, root = output .. "/aa-a" },
    { id = "aa-b", phase = "aa", label = "b", artifact_index = 1, root = output .. "/aa-b" },
    { id = "ab-a", phase = "ab", label = "a", artifact_index = 1, root = output .. "/ab-a" },
    { id = "ab-b", phase = "ab", label = "b", artifact_index = 2, root = output .. "/ab-b" },
  }
  metadata.fixtures = manifest
  metadata.counter_columns = { "compiled", "cached", "read", "verdict", "run", "builds" }
  save(output .. "/metadata.json", json_bounds(metadata))
  local fixtures: {Fixture} = {}
  for _, entry in ipairs(manifest) do
    fixtures[#fixtures + 1] = fixture(binaries[entry.artifact_index], entry.root)
  end
  local a, aa, parent, b = fixtures[1], fixtures[2], fixtures[3], fixtures[4]
  local afacts = assert(Json.decode_object((assert(Fs.read(a.logs .. "/runtime.json")))))
  local bfacts = assert(Json.decode_object((assert(Fs.read(b.logs .. "/runtime.json")))))
  assert(afacts.target == bfacts.target and afacts.configuration == bfacts.configuration,
    "baseline and candidate must use the same target/configuration")
  local has_true, _ = Fs.exists("/usr/bin/true")
  if has_true then
    local supervisor: {number} = {}
    for _ = 1, 30 do
      local start = Clock.monotonic_ns()
      command({ "/usr/bin/true" }, a)
      supervisor[#supervisor + 1] = Clock.monotonic_ns() - start
    end
    metadata.supervisor_with_true_ns = Perf.distribution(supervisor)
  else
    metadata.supervisor_with_true_ns = "unmeasured: /usr/bin/true unavailable"
  end
  save(output .. "/metadata.json", json_bounds(metadata))
  local raw: {Observation} = {}
  local summaries: {string:Reading} = {}
  local failed = false
  local stride = ((count + 4) // 2) * 2
  for index, w in ipairs(selected) do
    -- All four histories match only at workload boundaries, not between
    -- phases. Independent pairs advance once each through the same inputs.
    local before = latest_build(a)
    for _, f in ipairs(fixtures) do Perf.check_history(before, latest_build(f)) end
    local mutation_offset = 1000 + index * stride
    local calibration = run_pairs(a, aa, w, "aa", count, raw, index * stride * 2, mutation_offset)
    local samples = run_pairs(parent, b, w, "ab", count, raw, index * stride * 2 + stride, mutation_offset)
    local after = latest_build(a)
    for _, f in ipairs(fixtures) do Perf.check_history(after, latest_build(f)) end
    local compared = Perf.compare(calibration, samples)
    summaries[w.name] = compared
    failed = failed or compared.status ~= "pass"
    save(output .. "/raw.json", raw)
    save(output .. "/summary.json", json_bounds(summaries))
    print(string.format("%s: %s; median %.3f -> %.3f ms; A/A resolution %.3f ms",
      w.name, compared.status, compared.a.median / 1e6, compared.b.median / 1e6, compared.noise / 1e6))
    if #compared.reasons > 0 then print(w.name .. ": " .. table.concat(compared.reasons, ", ")) end
  end
  return failed and 2 or 0
end

return Perf
