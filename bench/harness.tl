--- The shared harness of the bench/ scripts: a suite of named cases, each timed best-of-N, one line or one JSON
--- object per case, and a compare mode that alternates two cosmic binaries over the same cases.
---
---     local Bench = require("bench.harness")
---     local bench = Bench.new("runtime")
---     bench.case("json.decode small", function(n: integer) for _ = 1, n do Json.decode(small) end end)
---     return bench.main
---
--- A case's body runs its operation `n` times. The harness doubles `n` until one batch takes `--target-ms`
--- (50 ms), then times `--rounds` batches (5) of that size and prints the fastest and the median, in ns per
--- operation. A case's [`Bench.Options`] add a setup that runs once, only when the case is selected; a byte
--- count, for a rate in GB/s; and a baseline case, for a ratio to it.
---
--- `--json` prints one JSON object per case, on a line of its own, in place of the table. `--against <binary>`
--- runs each round's batches in a child of each binary, the two alternating which goes first, and prints each
--- case's best on both sides, the ratio of new to old, and a 95% band for the median of the paired ratios. Both
--- children run a copy of bench/ outside the checkout, so each uses its own built-in standard library. The
--- harness measures; it gates nothing, and no test reads a case's numbers.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")

local record Bench
  --- What a case may add to its name and body.
  record Options
    --- Runs once before the case's first batch, and only when the case is selected: a fixture's cost that
    --- would slow every other run of the script.
    setup?: function()
    --- The bytes one operation reads, for a rate in GB/s beside the time.
    bytes?: integer
    --- The name of an earlier case, for the ratio of this case's best to that case's.
    baseline?: string
  end

  --- One named body and its options.
  record Case
    name: string
    run: function(n: integer)
    options: Options
  end

  --- One case's timings, in ns per operation.
  record Timing
    name: string
    --- The operations in a batch.
    n: integer
    --- Each batch's ns per operation, in the order taken.
    samples: {number}
    best: number
    median: number
  end

  --- One case measured on both sides of a compare.
  record Comparison
    name: string
    n: integer
    old: Timing
    new: Timing
    --- The new best over the old best: below 1 is faster.
    ratio: number
    --- The median of each round's new over old, and its 95% sign interval.
    paired: number
    low: number
    high: number
    --- "faster" or "slower" when the band leaves out 1, else "same".
    verdict: string
  end

  --- A script's cases and its entry point.
  record Suite
    name: string
    cases: mut {Case}
    --- Adds a case; a name already taken raises.
    case: function(name: string, run: function(n: integer), options?: Options)
    --- The script's entry point: return it from the script's top level.
    main: function(argv: {string}): integer
  end
end

local DEFAULT_ROUNDS <const> = 5
local DEFAULT_COMPARE_ROUNDS <const> = 20
-- A child's batches per round: the second is warm when the first paid for a cold cache.
local CHILD_BATCHES <const> = 2
-- The most operations a batch is sized to: a body that ignores its n never reaches the target.
local MAX_BATCH <const> = 1 << 30

local SPEC <const>: {string: boolean | Flags.Option} = {
  ["--json"] = { about = "one JSON object per case, a line each, in place of the table" },
  ["--list"] = { about = "print the case names and exit" },
  ["--rounds"] = { value = "n", integer = { min = 1, max = 1000 },
    about = "timed batches per case (default 5; 20 with --against, at least 6)" },
  ["--target-ms"] = { value = "ms", integer = { min = 1, max = 60000 }, default = "50",
    about = "the least length of one batch; n doubles until a batch takes it" },
  ["--against"] = { value = "binary", about = "compare: alternate this cosmic and the old cosmic at this path" },
  ["--binary"] = { value = "binary", about = "with --against: the new side's cosmic (default: this one)" },
  ["--sizes"] = { value = "path", about = "internal: a compare child's batch sizes, a JSON object of case to n" },
}

--- `values` sorted, and its fastest and median.
function Bench.timing(name: string, n: integer, samples: {number}): Bench.Timing
  assert(#samples > 0, "a timing needs a sample")
  local sorted: mut {number} = {}
  for i, v in ipairs(samples) do sorted[i] = v end
  table.sort(sorted)
  local middle = (#sorted + 1) // 2
  local median = assert(sorted[middle])
  if #sorted % 2 == 0 then median = (median + assert(sorted[middle + 1])) / 2 end
  return { name = name, n = n, samples = samples, best = assert(sorted[1]), median = median }
end

--- The 1-based ranks of a 95% sign interval for the median of `n` sorted values, as [`build.perf`]'s: the
--- largest `low` whose binomial(n, 1/2) tail below it holds at most 2.5%, and its mirror. Nil under six values.
local function sign_ranks(n: integer): integer?, integer?
  local log_mass = -n * math.log(2)
  local cumulative, low = 0.0, 0
  for k = 0, n do
    cumulative = cumulative + math.exp(log_mass)
    if cumulative > 0.025 then break end
    low = k + 1
    log_mass = log_mass + math.log((n - k) / (k + 1))
  end
  if low == 0 then return nil, nil end
  return low, n + 1 - low
end

--- Two sides' timings of one case, taken in rounds that alternate: each round's samples are a pair.
function Bench.compare(old: Bench.Timing, new: Bench.Timing): Bench.Comparison
  assert(#old.samples == #new.samples, "the two sides took different numbers of rounds")
  local ratios: mut {number} = {}
  for i, o in ipairs(old.samples) do ratios[i] = assert(new.samples[i]) / o end
  local paired = Bench.timing(new.name, new.n, ratios)
  local low_rank, high_rank = sign_ranks(#ratios)
  assert(low_rank ~= nil and high_rank ~= nil, "a band needs at least six rounds")
  local sorted: mut {number} = {}
  for i, r in ipairs(ratios) do sorted[i] = r end
  table.sort(sorted)
  local low, high = assert(sorted[low_rank]), assert(sorted[high_rank])
  local verdict = if high < 1 then "faster" elseif low > 1 then "slower" else "same" end
  return { name = new.name, n = new.n, old = old, new = new, ratio = new.best / old.best,
    paired = paired.median, low = low, high = high, verdict = verdict }
end

--- A time in ns, to three significant figures or as a whole number.
local function ns(value: number): string
  if value < 10 then return string.format("%.2f", value) end
  if value < 100 then return string.format("%.1f", value) end
  return string.format("%.0f", value)
end

local function samples_json(samples: {number}): Json.Value
  local out: mut {Json.Value} = {}
  for i, v in ipairs(samples) do out[i] = v end
  return Json.array(out)
end

local function encoded(value: {string: Json.Value}): string
  return assert(Json.encode(value))
end

--- What a suite's functions read of it.
local record Plan
  name: string
  cases: {Bench.Case}
end

--- Writes `text` and a newline to stderr.
local function complain(text: string)
  local _, _ = Fs.put(Fs.stderr, text .. "\n")
end

--- Writes `text` to stderr as it is.
local function progress(text: string)
  local _, _ = Fs.put(Fs.stderr, text)
end

--- The ns of one batch of `n` operations.
local function batch(c: Bench.Case, n: integer): integer
  collectgarbage("collect")
  local start = Clock.monotonic_ns()
  c.run(n)
  return Clock.monotonic_ns() - start
end

--- The batch size whose batch takes at least `target_ns`.
local function size(c: Bench.Case, target_ns: integer): integer
  local n = 1
  while batch(c, n) < target_ns do
    n = n * 2
    if n > MAX_BATCH then
      error(string.format("bench: %s took under %d ns for %d operations: does its body run its n times?", c.name,
        target_ns, MAX_BATCH), 0)
    end
  end
  return n
end

local function timed(c: Bench.Case, n: integer, rounds: integer): Bench.Timing
  local samples: mut {number} = {}
  for i = 1, rounds do samples[i] = batch(c, n) / n end
  return Bench.timing(c.name, n, samples)
end

--- The cases whose names hold any of `words`, all of them when there are none, or nil and why.
local function selected(suite: Plan, words: {string}): {Bench.Case}?, string
  local out: mut {Bench.Case} = {}
  local matched: mut {string: boolean} = {}
  for _, c in ipairs(suite.cases) do
    local take = #words == 0
    for _, word in ipairs(words) do
      if c.name:find(word, 1, true) ~= nil then
        take, matched[word] = true, true
      end
    end
    if take then out[#out + 1] = c end
  end
  for _, word in ipairs(words) do
    if matched[word] == nil then
      local names: mut {string} = {}
      for _, c in ipairs(suite.cases) do names[#names + 1] = c.name end
      return nil, string.format("no case of %s holds %q; its cases: %s", suite.name, word, table.concat(names, ", "))
    end
  end
  return out, ""
end

local function prepared(c: Bench.Case, done: mut {string: boolean})
  local setup = c.options.setup
  if setup ~= nil and done[c.name] == nil then setup() end
  done[c.name] = true
end

--- One case's line of the table.
local function line(c: Bench.Case, t: Bench.Timing, bests: {string: number}): string
  local text = string.format("%-32s %12s ns/op  (median %s, n=%d)", c.name, ns(t.best), ns(t.median), t.n)
  local bytes = c.options.bytes
  if bytes ~= nil then text = text .. string.format("  %.3f GB/s", bytes / t.best) end
  local baseline = c.options.baseline
  local base = if baseline ~= nil then bests[baseline] else nil end
  if baseline ~= nil and base ~= nil then
    text = text .. string.format("  %.2fx %s", t.best / base, baseline)
  end
  return text
end

local function record_of(suite: Plan, c: Bench.Case, t: Bench.Timing, bests: {string: number}): string
  local out: mut {string: Json.Value} = { suite = suite.name, case = c.name, unit = "ns/op", best = t.best,
    median = t.median, n = t.n, rounds = #t.samples, samples = samples_json(t.samples) }
  local bytes = c.options.bytes
  if bytes ~= nil then
    out["bytes"] = bytes
    out["gb_per_s"] = bytes / t.best
  end
  local baseline = c.options.baseline
  local base = if baseline ~= nil then bests[baseline] else nil end
  if baseline ~= nil and base ~= nil then
    out["baseline"] = baseline
    out["ratio"] = t.best / base
  end
  return encoded(out)
end

--- Times each case of `cases` here and prints its line or record.
local function run_here(suite: Plan, cases: {Bench.Case}, rounds: integer, target_ns: integer, json: boolean)
  local bests: mut {string: number} = {}
  local done: mut {string: boolean} = {}
  for _, c in ipairs(cases) do
    prepared(c, done)
    local t = timed(c, size(c, target_ns), rounds)
    bests[c.name] = t.best
    print(if json then record_of(suite, c, t, bests) else line(c, t, bests) end)
  end
end

--- A compare child: each case the sizes file names, `rounds` batches of its size, one record each.
local function run_sizes(suite: Plan, path: string, rounds: integer): integer
  local text, why = Fs.read(path)
  if text == nil then
    error("bench: cannot read the sizes file " .. path .. ": " .. tostring(why))
  end
  local sizes = assert(Json.decode_object(text))
  local done: mut {string: boolean} = {}
  for _, c in ipairs(suite.cases) do
    local n = math.tointeger(sizes[c.name])
    if n ~= nil then
      prepared(c, done)
      local t = timed(c, n, rounds)
      print(encoded({ case = c.name, best = t.best }))
    end
  end
  return 0
end

--- One side of a compare: how to start its binary, and its copy of bench/.
local record Side
  label: string
  binary: string
  argv: {string}
  env: {string: string}
  fds: {integer: integer | string}
  root: string
  script: string
  --- Each case's ns per operation, a sample a round.
  samples: mut {string: mut {number}}
end

local function side(label: string, argv: {string}, env: {string: string}, fds: {integer: integer | string},
                    tmp: string, bench_dir: string, script_name: string): Side
  local root = tmp .. "/" .. label
  assert(Fs.mkdirs(root))
  assert(Fs.copy_tree(bench_dir, root .. "/bench"))
  local whole: mut {string: string} = Env.all()
  for name, value in pairs(env) do whole[name] = value end
  -- Each side builds its copy into its own directory under `tmp`, so removing `tmp` removes the builds.
  whole["COSMIC_BUILD_HOME"] = tmp .. "/" .. label .. "-build"
  return { label = label, binary = assert(argv[1]), argv = argv, env = whole, fds = fds, root = root,
    script = root .. "/bench/" .. script_name, samples = {} }
end

--- Runs `s`'s copy of the script with `words`, and returns its stdout, or raises with what it said.
local function child(s: Side, words: {string}): string
  local argv: mut {string} = {}
  for _, word in ipairs(s.argv) do argv[#argv + 1] = word end
  argv[#argv + 1] = s.script
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local result, why = Child.run(argv, { cwd = s.root, env = s.env, fds = s.fds, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(600) })
  if result == nil then
    error("bench: cannot start the " .. s.label .. " cosmic " .. s.binary .. ": " .. tostring(why), 0)
  end
  if not result.ok then
    error(string.format("bench: the %s cosmic %s failed on %s (exit %s); a case may use what that binary lacks:\n%s",
      s.label, s.binary, s.script, tostring(result.code), result.stderr or ""), 0)
  end
  return result.stdout or ""
end

--- The ns per operation each case took in one child's output.
local function bests_of(output: string): {string: number}
  local out: mut {string: number} = {}
  for text in output:gmatch("[^\n]+") do
    local row, _ = Json.decode_object(text)
    if row ~= nil then
      local name, best = row["case"], row["best"]
      if name is string and best is number then out[name] = best end
    end
  end
  return out
end

local function compared_line(c: Bench.Comparison): string
  return string.format("%-32s %12s %12s  %6.3f  [%.3f, %.3f]  %s", c.name, ns(c.old.best), ns(c.new.best),
    c.ratio, c.low, c.high, c.verdict)
end

local function compared_record(suite: Plan, c: Bench.Comparison, old: string, new: string): string
  local function side_json(t: Bench.Timing, binary: string): Json.Value
    return { binary = binary, best = t.best, median = t.median, samples = samples_json(t.samples) }
  end
  return encoded({ suite = suite.name, case = c.name, unit = "ns/op", n = c.n, rounds = #c.new.samples,
    old = side_json(c.old, old), new = side_json(c.new, new), ratio = c.ratio, paired = c.paired,
    low = c.low, high = c.high, verdict = c.verdict })
end

--- Compare mode: sizes each case here, then alternates the two binaries' children for `rounds` rounds.
local function run_against(suite: Plan, cases: {Bench.Case}, got: Flags.Parsed, rounds: integer,
                           target_ns: integer, json: boolean): integer
  if rounds < 6 then
    complain("bench: --against needs at least 6 rounds for its band")
    return 2
  end
  local launched, why = Proc.relaunch()
  if launched == nil or launched.script == nil then
    complain("bench: --against runs under `cosmic <file.tl>`: " .. tostring(why))
    return 2
  end
  local script = assert(launched.script)
  local bench_dir = Fs.dirname(script)
  local new_argv, new_env, new_fds: {string}, {string: string}, {integer: integer | string} =
    launched.argv, launched.env, launched.fds
  local given = got.values["--binary"]
  if given ~= nil then new_argv, new_env, new_fds = { given }, {}, {} end
  local old_path = assert(got.values["--against"])
  local tmp = assert(Fs.mkdtemp("cosmic-bench-"))
  local ok, err = pcall(function()
    local name = Fs.basename(script)
    local new = side("new", new_argv, new_env, new_fds, tmp, bench_dir, name)
    local old = side("old", { old_path }, {}, {}, tmp, bench_dir, name)
    -- Sizes come from this process, so both sides run the same batches.
    local sizes: mut {string: Json.Value} = {}
    local done: mut {string: boolean} = {}
    for _, c in ipairs(cases) do
      prepared(c, done)
      sizes[c.name] = size(c, target_ns)
    end
    local sizes_path = tmp .. "/sizes.json"
    assert(Fs.write(sizes_path, encoded(sizes)))
    local words = { "--sizes", sizes_path, "--rounds", tostring(CHILD_BATCHES) }
    -- One untimed child each builds its copy and warms the page cache.
    child(new, words)
    child(old, words)
    local tty = Proc.is_tty(2)
    for round = 1, rounds do
      if tty then progress(string.format("\rround %d/%d", round, rounds)) end
      local order = if round % 2 == 1 then { new, old } else { old, new } end
      for _, s in ipairs(order) do
        local bests = bests_of(child(s, words))
        for _, c in ipairs(cases) do
          local best = bests[c.name]
          if best == nil then
            error("bench: the " .. s.label .. " cosmic printed no time for " .. c.name, 0)
          end
          local list = s.samples[c.name] or {}
          list[#list + 1] = best
          s.samples[c.name] = list
        end
      end
    end
    if tty then progress("\r") end
    if not json then
      print(string.format("%-32s %12s %12s  %6s  %-16s  %s", "case (ns/op, best of " .. tostring(rounds) .. ")",
        "old", "new", "new/old", "95% band", "verdict"))
    end
    for _, c in ipairs(cases) do
      local n = math.tointeger(sizes[c.name]) or 1
      local compared = Bench.compare(Bench.timing(c.name, n, assert(old.samples[c.name])),
        Bench.timing(c.name, n, assert(new.samples[c.name])))
      print(if json then compared_record(suite, compared, old.binary, new.binary) else compared_line(compared) end)
    end
  end)
  local _, _ = Fs.remove_tree(tmp)
  if not ok then
    complain(tostring(err))
    return 1
  end
  return 0
end

--- A new suite named `name`, with no cases.
function Bench.new(name: string): Bench.Suite
  local cases: mut {Bench.Case} = {}
  local names: mut {string: boolean} = {}
  local suite: Plan = { name = name, cases = cases }
  local function add(case_name: string, run: function(n: integer), options?: Bench.Options)
    if names[case_name] == true then
      error("bench: " .. name .. " has two cases named " .. case_name, 2)
    end
    names[case_name] = true
    cases[#cases + 1] = { name = case_name, run = run, options = options or {} }
  end
  local function main(argv: {string}): integer
    local got, why = Flags.parse(argv, 1, SPEC)
    if got == nil then
      complain("bench: " .. why)
      return 2
    end
    if got.set["--list"] == true then
      for _, c in ipairs(cases) do print(c.name) end
      return 0
    end
    local sizes = got.values["--sizes"]
    if sizes ~= nil then
      return run_sizes(suite, sizes, got.integers["--rounds"] or CHILD_BATCHES)
    end
    local picked, refusal = selected(suite, got.words)
    if picked == nil then
      complain("bench: " .. refusal)
      return 2
    end
    local target_ns = (got.integers["--target-ms"] or 50) * 1000 * 1000
    local json = got.set["--json"] == true
    if got.values["--against"] ~= nil then
      return run_against(suite, picked, got, got.integers["--rounds"] or DEFAULT_COMPARE_ROUNDS, target_ns, json)
    end
    if got.values["--binary"] ~= nil then
      complain("bench: --binary names the new side of --against")
      return 2
    end
    run_here(suite, picked, got.integers["--rounds"] or DEFAULT_ROUNDS, target_ns, json)
    return 0
  end
  return { name = name, cases = cases, case = add, main = main }
end

return Bench
