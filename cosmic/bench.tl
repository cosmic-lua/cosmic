--- Benches: a top-level `local function bench_<name>(b: Bench.B)` of a `*_test.tl` file times one operation. Its
--- body runs the operation `b.n` times:
---
---     local Bench = require("cosmic.bench")
---     local Json = require("cosmic.json")
---
---     local function bench_decode_small(b: Bench.B)
---       local text = '{"a":1,"b":[true,false]}'
---       b.bytes = #text
---       b.reset()
---       for _ = 1, b.n do Json.decode(text) end
---     end
---
--- `cosmic test` calls it once, with `b.n` 1, as a test: it fails when it raises, so a bench cannot rot while no one
--- times it. `cosmic test --bench` times it: it calls the body with `b.n` doubled until one call takes the target
--- time (`--target-ms`, 50), then times `--rounds` calls (5) of that size, and prints the fastest and the median ns
--- per operation, or one JSON object per bench with `--json` ([`Bench.record`]). A call's clock starts after a full
--- garbage collection, and again at each `b.reset()`, so the work before the loop is setup. doc/testing.md
--- ("benches") says more; doc/decisions/0002-one-companion-one-runner.md says why a bench is a function of a test file.
---
--- [`timing`] and [`compare`] are the statistics of the timings, which a program that times its own work uses too.
local Json = require("cosmic.json")

local record Bench
  --- What the runner hands a bench's body.
  record B
    --- How many times the body runs its operation.
    n: integer
    --- Starts the call's clock again: what the body did before is not timed.
    reset: function()
    --- The bytes one operation reads, which the body sets for a rate in GB/s beside the time; 0 for none.
    mut bytes: integer
    --- A directory of the bench's own, as a test is handed one.
    dir: string
  end

  --- One bench's timings, in ns per operation.
  record Timing
    --- The bench's name.
    name: string
    --- The operations in a batch.
    n: integer
    --- Each batch's ns per operation, in the order taken.
    samples: {number}
    --- The fastest sample.
    best: number
    --- The median sample.
    median: number
    --- The bytes one operation reads, 0 for none.
    bytes: integer
  end

  --- One bench timed on two sides, in rounds that alternate.
  record Comparison
    --- The bench's name.
    name: string
    --- The operations in a batch of the new side.
    n: integer
    --- The old side's timing.
    old: Timing
    --- The new side's timing.
    new: Timing
    --- The new best over the old best: below 1 is faster.
    ratio: number
    --- The median of each round's new over old.
    paired: number
    --- The low end of the 95% sign interval of `paired`.
    low: number
    --- The high end of the 95% sign interval of `paired`.
    high: number
    --- "faster" or "slower" when the band leaves out 1, else "same".
    verdict: string
  end
end

--- A timing of `samples` (ns per operation), kept in order, with their fastest and median. `bytes` is what one
--- operation reads, 0 or nil for none.
function Bench.timing(name: string, n: integer, samples: {number}, bytes?: integer): Bench.Timing
  assert(#samples > 0, "a timing needs a sample")
  local sorted: mut {number} = {}
  for i, v in ipairs(samples) do sorted[i] = v end
  table.sort(sorted)
  local middle = (#sorted + 1) // 2
  local median = assert(sorted[middle])
  if #sorted % 2 == 0 then median = (median + assert(sorted[middle + 1])) / 2 end
  return { name = name, n = n, samples = samples, best = assert(sorted[1]), median = median, bytes = bytes or 0 }
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

--- Two sides' timings of one bench, taken in rounds that alternate: each round's samples are a pair. Raises under
--- six rounds, which give no band.
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
function Bench.ns(value: number): string
  if value < 10 then return string.format("%.2f", value) end
  if value < 100 then return string.format("%.1f", value) end
  return string.format("%.0f", value)
end

--- One timing's line of a table: its name, padded to `width` (32 by default), its fastest and median ns per
--- operation, its batch size, and its rate where it reads bytes.
function Bench.line(t: Bench.Timing, width?: integer): string
  local text = string.format("%-" .. tostring(width or 32) .. "s %12s ns/op  (median %s, n=%d)", t.name,
    Bench.ns(t.best), Bench.ns(t.median), t.n)
  if t.bytes > 0 then text = text .. string.format("  %.3f GB/s", t.bytes / t.best) end
  return text
end

--- One timing as a JSON object on one line: `name`, `unit` ("ns/op"), `best`, `median`, `n`, `rounds` and
--- `samples`, with `bytes` and `gb_per_s` where it reads bytes.
function Bench.record(t: Bench.Timing): string
  local samples: mut {Json.Value} = {}
  for i, v in ipairs(t.samples) do samples[i] = v end
  local out: mut {string: Json.Value} = { name = t.name, unit = "ns/op", best = t.best, median = t.median,
    n = t.n, rounds = #t.samples, samples = Json.array(samples) }
  if t.bytes > 0 then
    out["bytes"] = t.bytes
    out["gb_per_s"] = t.bytes / t.best
  end
  return assert(Json.encode(out))
end

--- The header of [`Bench.compared_line`]'s table, for `rounds` rounds.
function Bench.compared_header(rounds: integer, width?: integer): string
  return string.format("%-" .. tostring(width or 32) .. "s %12s %12s  %7s  %7s  %-16s  %s",
    "bench (ns/op, best of " .. tostring(rounds) .. ")", "old", "new", "best", "paired", "95% band", "verdict")
end

--- One comparison's line of a table: its name, padded to `width` (32 by default), each side's fastest ns per
--- operation, the ratio of the bests, the paired ratio, its 95% band and the verdict.
function Bench.compared_line(c: Bench.Comparison, width?: integer): string
  return string.format("%-" .. tostring(width or 32) .. "s %12s %12s  %7.3f  %7.3f  %-16s  %s", c.name,
    Bench.ns(c.old.best), Bench.ns(c.new.best), c.ratio, c.paired, string.format("[%.3f, %.3f]", c.low, c.high),
    c.verdict)
end

--- One comparison as a JSON object on one line: `name`, `unit`, `rounds`, `old` and `new` (each its `binary`,
--- `best`, `median`, `n` and `samples`), `ratio`, `paired`, `low`, `high` and `verdict`.
function Bench.compared_record(c: Bench.Comparison, old_binary: string, new_binary: string): string
  local function side(t: Bench.Timing, binary: string): Json.Value
    local samples: mut {Json.Value} = {}
    for i, v in ipairs(t.samples) do samples[i] = v end
    return { binary = binary, best = t.best, median = t.median, n = t.n, samples = Json.array(samples) }
  end
  return assert(Json.encode({ name = c.name, unit = "ns/op", rounds = #c.new.samples,
    old = side(c.old, old_binary), new = side(c.new, new_binary), ratio = c.ratio, paired = c.paired,
    low = c.low, high = c.high, verdict = c.verdict }))
end

return Bench
