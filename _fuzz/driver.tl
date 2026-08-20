--- Seeded property loop for fuzz tests.
--- run() draws one Recorder per iteration from a seeded rand.Source,
--- generates an input from it, and asserts a property on that input.
--- Every fuzz test in the tree shares it, so failures are reported the
--- same way and every failure is replayable: the message names the
--- seed, the iteration, the failing input in base64 and its draw
--- count, and rerunning with FUZZ_SEED=<seed> reaches the same input
--- at the same iteration.
---
--- Environment: FUZZ_SEED sets the seed (default 1), FUZZ_ITERS the
--- iteration count (default 256). Options.iters overrides FUZZ_ITERS.
---
--- run() always isolates: before running a property's iterations it
--- re-invokes this same process as a child (FUZZ_ISOLATE names the
--- property so every OTHER property in the file no-ops), so a C-layer
--- crash inside check() is caught as a signaled child instead of
--- taking down the whole file. On a crash, the failing iteration is
--- found by re-spawning the child with a bisected FUZZ_ITERS. A hang
--- past Options.timeout_ms is reported the same way. FUZZ_ISOLATE is
--- internal — set by run() itself, never by a caller.

local child = require("cosmic.child")
local codec = require("cosmic.codec")
local env = require("cosmic.env")
local proc = require("cosmic.proc")
local rand = require("cosmic.rand")
local shrink = require("_fuzz.shrink")
local source = require("_fuzz.source")

local DEFAULT_SEED = 1
local DEFAULT_ITERS = 256

--- VM instructions one check() invocation may spend before the run
--- fails. Measured 2026-08-20 with a count hook at 1000-instruction
--- granularity over every property in the tree: the costliest single
--- invocation (tar_mutation_totality) stayed under 23k instructions,
--- so this default sits more than 2000x above what the tree needs.
local DEFAULT_BUDGET = 50000000

--- What the budget hook throws. Raised with level 0, so a caught value
--- equal to this string IS a budget failure, not a property throw.
local BUDGET_MESSAGE = "_fuzz.driver: instruction budget exceeded"

--- Wall-clock backstop for the isolated child, in milliseconds. Only
--- reached when the VM instruction hook cannot arm (its slot is taken
--- by the coverage collector) or the hang is inside a single C call,
--- both outside the hook's reach. Options.timeout_ms overrides it.
local DEFAULT_TIMEOUT_MS = 30000

--- Arm the budget hook when the VM's one hook slot is free.
--- @param budget integer VM instructions until the hook throws
--- @return boolean True when the hook was armed
local function arm_budget(budget: integer): boolean
  if debug.gethook() ~= nil then
    return false
  end
  debug.sethook(function() error(BUDGET_MESSAGE, 0) end, "", budget)
  return true
end

--- Turn the budget hook off. tl's sethook declaration has no argless
--- clearing form; an empty mask with no count is the same off state
--- (Lua turns the hook off when mask and count are both zero).
local function disarm_budget()
  debug.sethook(function() end, "")
end

--- One fuzz property: what to generate, and what must hold for it.
local record Options
  --- Reported at the head of every message.
  name: string
  --- Produces one input per call, drawing from src.
  gen: function(src: source.Recorder): string
  --- The property: true when it holds, or false plus what failed.
  --- A throw is treated exactly like a false return.
  check: function(input: string): boolean, string
  --- Iteration count. Overrides FUZZ_ITERS when set.
  iters: integer
  --- VM instructions per check() invocation. Overrides DEFAULT_BUDGET
  --- when set. A property that runs past it fails the run like any
  --- other failure, reporting `budget=<n> exceeded`, so a hung parser
  --- is attributed to its input instead of hanging the suite. The VM
  --- has one debug-hook slot, so the budget arms only when that slot
  --- is free: under the instrumented coverage stage the collector owns
  --- it (cosmo.cov's C hook, which Lua can neither call nor reinstall)
  --- and the budget stands down. A hang inside a single C call cannot
  --- be caught either way — the hook fires between VM instructions.
  budget: integer
  --- Milliseconds the isolated child may run before it is treated as
  --- hung. Overrides DEFAULT_TIMEOUT_MS when set.
  timeout_ms: integer
end

--- Read an integer from the environment, falling back when unset or
--- unparseable.
--- @param name string The environment variable to read
--- @param fallback integer The value to use when it is absent or not a number
--- @return integer The parsed value, or `fallback`
local function env_integer(name: string, fallback: integer): integer
  local raw = env.get(name)
  if not raw then
    return fallback
  end
  local parsed = tonumber(raw)
  if not parsed then
    return fallback
  end
  return math.floor(parsed)
end

--- Format the one failure message shape every fuzz test reports.
--- @param name string The property name
--- @param seed integer The seed the run used
--- @param iteration integer The 1-based iteration that failed
--- @param input string The failing input
--- @param draws integer How many values the generator drew for this input
--- @param detail string What the property reported, or the thrown error
--- @return string The failure message
local function failure(
    name: string,
    seed: integer,
    iteration: integer,
    input: string,
    draws: integer,
    detail: string
  ): string
  return string.format(
    "%s: seed=%d iteration=%d input(base64)=%s draws=%d: %s",
    name, seed, iteration, codec.encode_base64(input), draws, detail)
end

--- Run a fuzz property over generated inputs, in this process.
--- Draws one Recorder per iteration from rand.insecure_source(seed +
--- iteration), then generates and checks inputs until one fails or the
--- iteration count is exhausted. The property runs under pcall, so a
--- throw fails the run instead of escaping it, and — when the VM's
--- hook slot is free — under an instruction-count hook, so a property
--- that stops terminating fails within its budget instead of hanging.
--- A crash (a C-layer fault) still takes this process down; run()
--- calls this only inside an already-isolated child, where that is
--- safe.
--- @param opts Options The property to run
--- @param seed integer The seed to draw from
--- @param iters integer How many iterations to run
--- @param budget integer VM instructions check() may spend per iteration
--- @return boolean True when every iteration held
--- @return string The failure message, or a summary of the passing run
local function run_in_process(
    opts: Options, seed: integer, iters: integer, budget: integer
  ): boolean, string
  for i = 1, iters do
    local rec = source.new(rand.insecure_source(seed + i))
    local input = opts.gen(rec)
    local armed = arm_budget(budget)
    local ok, held, detail = pcall(opts.check, input)
    if armed then
      disarm_budget()
    end
    if not ok or not held then
      local what: string
      if not ok then
        local thrown = tostring(held)
        what = "threw: " .. thrown
        if thrown == BUDGET_MESSAGE then
          what = ("budget=%d exceeded"):format(budget)
        end
      else
        what = tostring(detail or "no detail")
      end
      local minimized_draws = shrink.shrink(opts.gen, opts.check, rec.draws)
      local minimized_input = opts.gen(source.replay(minimized_draws))
      return false, failure(opts.name, seed, i, minimized_input, #minimized_draws, what)
    end
  end
  return true, string.format("%s: %d iterations, seed=%d", opts.name, iters, seed)
end

--- Re-invoke this same process as a child, isolated to one property.
--- The child sees FUZZ_ISOLATE=name (so every other property in the
--- file no-ops in run(), see below) and FUZZ_SEED/FUZZ_ITERS pinned to
--- the values this run uses, overriding whatever the parent's own
--- environment set.
--- @param argv {string} {interpreter path, this script's path}
--- @param name string The property to isolate
--- @param seed integer The seed to pin
--- @param iters integer The iteration count to pin
--- @param timeout_ms integer Milliseconds before the child counts as hung
--- @return child.Result | nil The child's result, or nil on a timeout or a
--- failure to start
--- @return string? Why there is no Result
local function spawn_isolated(
    argv: {string}, name: string, seed: integer, iters: integer, timeout_ms: integer
  ): child.Result | nil, string
  local child_env = env.list({set = {
        FUZZ_ISOLATE = name,
        FUZZ_SEED = tostring(seed),
        FUZZ_ITERS = tostring(iters),
      }})
  local h, err = child.start(argv, {env = child_env})
  if not h then
    return nil, err or "start failed"
  end
  return h:wait(timeout_ms)
end

--- Find the smallest iteration count that still reproduces a crash.
--- `hi` is known to crash (the caller just observed it); binary search
--- narrows to the least such count, which is the failing iteration.
--- @param argv {string} {interpreter path, this script's path}
--- @param name string The property to isolate
--- @param seed integer The seed to pin
--- @param timeout_ms integer Milliseconds before a respawn counts as hung
--- @param hi integer An iteration count already known to crash
--- @return integer The smallest iteration count that still crashes
local function bisect_crash(
    argv: {string}, name: string, seed: integer, timeout_ms: integer, hi: integer
  ): integer
  local lo = 1
  while lo < hi do
    local mid = (lo + hi) // 2
    local r = spawn_isolated(argv, name, seed, mid, timeout_ms)
    if r and r.signal then
      hi = mid
    else
      lo = mid + 1
    end
  end
  return lo
end

--- Run one property isolated in a child process, classifying its
--- Result into the same true/false, message shape run_in_process
--- reports: a clean exit passes through, an ordinary property failure
--- forwards the child's captured stderr (the standard failure()
--- message it already printed via check.truthy), a crash bisects the
--- failing iteration and reports it "crashed: signal N", and a timeout
--- reports "hung: exceeded <timeout_ms>ms" against the full iteration
--- count (not bisected — see Non-goals in the item that added this).
--- @param opts Options The property to run
--- @param seed integer The seed to draw from
--- @param iters integer How many iterations to run
--- @param budget integer VM instructions check() may spend per iteration
--- @return boolean True when every iteration held
--- @return string The failure message, or a summary of the passing run
local function isolate(
    opts: Options, seed: integer, iters: integer, budget: integer
  ): boolean, string
  local cosmic_bin = proc.interpreter()
  if not cosmic_bin then
    -- arg[-1] unresolvable (no known case in this tree's own test
    -- runners): isolation is impossible, so fall back to the
    -- unisolated loop rather than failing every property outright.
    return run_in_process(opts, seed, iters, budget)
  end
  local argv = {cosmic_bin, arg[0]}
  local timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS
  local r, err = spawn_isolated(argv, opts.name, seed, iters, timeout_ms)
  if not r then
    if err == "timeout" then
      return false, failure(opts.name, seed, iters, "", 0,
        ("hung: exceeded %dms"):format(timeout_ms))
    end
    return false, failure(opts.name, seed, iters, "", 0,
      "isolation failed: " .. (err or "unknown error"))
  end
  if r.signal then
    local crash_iteration = bisect_crash(argv, opts.name, seed, timeout_ms, iters)
    local rec = source.new(rand.insecure_source(seed + crash_iteration))
    local input = opts.gen(rec)
    return false, failure(opts.name, seed, crash_iteration, input, #rec.draws,
      ("crashed: signal %d"):format(r.signal))
  end
  if r.code == 0 then
    return true, string.format("%s: %d iterations, seed=%d", opts.name, iters, seed)
  end
  return false, ((r.stderr or ""):gsub("%s+$", ""))
end

--- Run a property in this process, without isolation: resolves
--- seed/iters/budget exactly like run() does, then calls
--- run_in_process() directly, never spawning a child. For
--- driver_test.tl's own tests of the loop's mechanics (shrinking,
--- replay, message format, budget) — a real `*_fuzz_test.tl` property
--- must call run(), never this, or a C-layer crash takes its whole
--- file down with no attribution.
--- @param opts Options The property to run
--- @return boolean True when every iteration held
--- @return string The failure message, or a summary of the passing run
local function run_unisolated(opts: Options): boolean, string
  local seed = env_integer("FUZZ_SEED", DEFAULT_SEED)
  local iters = opts.iters or env_integer("FUZZ_ITERS", DEFAULT_ITERS)
  local budget = opts.budget or DEFAULT_BUDGET
  return run_in_process(opts, seed, iters, budget)
end

--- Run a fuzz property over generated inputs.
--- Always isolates: unless FUZZ_ISOLATE is already set (meaning this
--- call IS the isolated child), spawns one child per property and
--- interprets its Result — see the module comment and `isolate()`.
--- Inside an isolated child, every OTHER property's run() call in the
--- same file no-ops instead of generating or checking anything, so
--- only the one property FUZZ_ISOLATE names actually runs.
--- @param opts Options The property to run
--- @return boolean True when every iteration held
--- @return string The failure message, or a summary of the passing run
local function run(opts: Options): boolean, string
  local isolating = env.get("FUZZ_ISOLATE")
  if isolating then
    if isolating ~= opts.name then
      return true, opts.name .. ": skipped (isolating a different property)"
    end
    -- Inside the isolated child, FUZZ_ITERS is the parent's pin — a
    -- bisection probe narrowing toward a crash — so it outranks
    -- opts.iters here, the one place that priority differs from
    -- everywhere else opts.iters is read.
    local seed = env_integer("FUZZ_SEED", DEFAULT_SEED)
    local iters = env_integer("FUZZ_ITERS", opts.iters or DEFAULT_ITERS)
    local budget = opts.budget or DEFAULT_BUDGET
    return run_in_process(opts, seed, iters, budget)
  end
  local seed = env_integer("FUZZ_SEED", DEFAULT_SEED)
  local iters = opts.iters or env_integer("FUZZ_ITERS", DEFAULT_ITERS)
  local budget = opts.budget or DEFAULT_BUDGET
  return isolate(opts, seed, iters, budget)
end

--- Generate a random byte string.
--- The length is uniform in [0, max_len] and every byte is uniform in
--- [0, 255], so the result is arbitrary binary, not text.
--- @param src source.Recorder The source to draw from
--- @param max_len integer The longest string to produce
--- @return string The generated bytes
local function bytes(src: source.Recorder, max_len: integer): string
  if max_len < 1 then
    return ""
  end
  local n = src:int(0, max_len)
  local out: {string} = {}
  for i = 1, n do
    out[i] = string.char(src:int(0, 255))
  end
  return table.concat(out)
end

--- Mutate a sample by applying random single-byte edits.
--- Each edit is a flip, an insert or a delete, chosen uniformly; an edit
--- on an empty string is always an insert, so every edit changes the
--- string.
--- @param src source.Recorder The source to draw from
--- @param sample string The string to mutate
--- @param edits integer How many edits to apply
--- @return string The mutated string
local function mutate(src: source.Recorder, sample: string, edits: integer): string
  local out = sample
  for _ = 1, edits do
    local n = #out
    local kind = src:int(1, 3)
    if n == 0 then
      kind = 2
    end
    if kind == 1 then
      local pos = src:int(1, n)
      out = out:sub(1, pos - 1) .. string.char(src:int(0, 255)) .. out:sub(pos + 1)
    elseif kind == 2 then
      local pos = src:int(1, n + 1)
      out = out:sub(1, pos - 1) .. string.char(src:int(0, 255)) .. out:sub(pos)
    else
      local pos = src:int(1, n)
      out = out:sub(1, pos - 1) .. out:sub(pos + 1)
    end
  end
  return out
end

local record DriverModule
  type Options = Options
  run: function(opts: Options): boolean, string
  run_unisolated: function(opts: Options): boolean, string
  bytes: function(src: source.Recorder, max_len: integer): string
  mutate: function(src: source.Recorder, sample: string, edits: integer): string
end

local M: DriverModule = {
  run = run,
  run_unisolated = run_unisolated,
  bytes = bytes,
  mutate = mutate,
}

return M
