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

local codec = require("cosmic.codec")
local env = require("cosmic.env")
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

--- Run a fuzz property over generated inputs.
--- Draws one Recorder per iteration from rand.insecure_source(seed +
--- iteration), seeded by FUZZ_SEED (default 1), then generates and
--- checks inputs until one fails or the iteration count is exhausted.
--- The property runs under pcall, so a throw fails the run instead of
--- escaping it, and — when the VM's hook slot is free — under an
--- instruction-count hook, so a property that stops terminating fails
--- within its budget instead of hanging.
--- @param opts Options The property to run
--- @return boolean True when every iteration held
--- @return string The failure message, or a summary of the passing run
local function run(opts: Options): boolean, string
  local seed = env_integer("FUZZ_SEED", DEFAULT_SEED)
  local iters = opts.iters or env_integer("FUZZ_ITERS", DEFAULT_ITERS)
  local budget = opts.budget or DEFAULT_BUDGET
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
  bytes: function(src: source.Recorder, max_len: integer): string
  mutate: function(src: source.Recorder, sample: string, edits: integer): string
end

local M: DriverModule = {
  run = run,
  bytes = bytes,
  mutate = mutate,
}

return M
