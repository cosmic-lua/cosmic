--- Property-based testing for Teal.
--- Generates random inputs, checks properties, and shrinks failures to minimal
--- counterexamples. Uses cosmic.rand for entropy.
---
--- Example usage:
---   local proptest = require("cosmic.proptest")
---   local gen = proptest.gen
---   proptest.check("encode roundtrip", gen.string(80), function(s: string)
---     local encoded = url.encode(s)
---     local decoded = url.decode(encoded)
---     assert(decoded == s)
---   end)
local rand = require("cosmic.rand")

-- RNG: seeded LCG wrapping rand64
local record RNG
  state: integer
end

local function new_rng(seed: integer): RNG
  return {state = seed}
end

-- LCG step: multiplier and addend chosen for 64-bit Lua integers
local LCG_MUL < const > = 6364136223846793005
local LCG_ADD < const > = 1442695040888963407

local function rng_next(rng: RNG): integer
  rng.state = rng.state * LCG_MUL + LCG_ADD
  return rng.state
end

-- Returns a value in [0, range) using rejection sampling
local function rng_range(rng: RNG, lo: integer, hi: integer): integer
  if lo >= hi then
    return lo
  end
  local span = hi - lo + 1
  -- use absolute value to avoid negative modulo issues
  local v = rng_next(rng)
  if v < 0 then
    v = -v
  end
  if v < 0 then
    -- math.mininteger edge case
    v = 0
  end
  return lo + (v % span)
end

-- Generator record: generate produces a value, shrink produces simpler candidates
local record Gen
  generate: function(RNG, integer): any
  shrink: function(any): {any}
end

-- Module gen namespace (populated below)
local record GenModule
  integer: function(lo?: integer, hi?: integer): Gen
  boolean: function(): Gen
  string: function(max_len?: integer): Gen
  bytes: function(max_len?: integer): Gen
  one_of: function(values: {any}): Gen
  list_of: function(g: Gen, max_len?: integer): Gen
  map: function(g: Gen, fn: function(any): any): Gen
  such_that: function(g: Gen, pred: function(any): boolean, max_retries: integer): Gen
end

-- integer generator: shrinks toward 0
local function gen_integer(lo?: integer, hi?: integer): Gen
  local lo_v = lo or -1000
  local hi_v = hi or 1000
  return {
    generate = function(rng: RNG, _size: integer): any
      return rng_range(rng, lo_v, hi_v)
    end,
    shrink = function(v: any): {any}
      local n = v as integer
      if n == 0 or (lo_v >= 0 and n == lo_v) then
        return {}
      end
      local candidates: {any} = {}
      -- halve toward 0 (clamped to range)
      local half = math.floor(n / 2)
      if half >= lo_v and half <= hi_v then
        table.insert(candidates, half)
      end
      -- try one step toward 0
      local step = (n > 0) and (n - 1) or (n + 1)
      if step >= lo_v and step <= hi_v then
        table.insert(candidates, step)
      end
      return candidates
    end,
  }
end

-- boolean generator: shrinks to false
local function gen_boolean(): Gen
  return {
    generate = function(rng: RNG, _size: integer): any
      return rng_range(rng, 0, 1) == 1
    end,
    shrink = function(v: any): {any}
      if v as boolean then
        return {false}
      end
      return {}
    end,
  }
end

-- printable ASCII characters (32..126)
local PRINTABLE_LO < const > = 32
local PRINTABLE_HI < const > = 126

-- string generator: random printable ASCII, length scaled by size
local function gen_string(max_len?: integer): Gen
  local ml = max_len or 100
  return {
    generate = function(rng: RNG, size: integer): any
      local max_sz = math.max(1, math.floor(ml * size / 100))
      local len = rng_range(rng, 0, max_sz)
      local chars: {string} = {}
      for _ = 1, len do
        table.insert(chars, string.char(rng_range(rng, PRINTABLE_LO, PRINTABLE_HI)))
      end
      return table.concat(chars)
    end,
    shrink = function(v: any): {any}
      local s = v as string
      if #s == 0 then
        return {}
      end
      -- try removing the last character
      return {s:sub(1, #s - 1)}
    end,
  }
end

-- bytes generator: random bytes, length scaled by size
local function gen_bytes(max_len?: integer): Gen
  local ml = max_len or 100
  return {
    generate = function(rng: RNG, size: integer): any
      local max_sz = math.max(1, math.floor(ml * size / 100))
      local len = rng_range(rng, 0, max_sz)
      local bs: {string} = {}
      for _ = 1, len do
        table.insert(bs, string.char(rng_range(rng, 0, 255)))
      end
      return table.concat(bs)
    end,
    shrink = function(v: any): {any}
      local s = v as string
      if #s == 0 then
        return {}
      end
      return {s:sub(1, #s - 1)}
    end,
  }
end

-- one_of generator: pick uniformly from a set of values
local function gen_one_of(values: {any}): Gen
  return {
    generate = function(rng: RNG, _size: integer): any
      local idx = rng_range(rng, 1, #values)
      return values[idx]
    end,
    shrink = function(v: any): {any}
      -- return smaller-index candidates
      local candidates: {any} = {}
      for i, val in ipairs(values) do
        if val == v and i > 1 then
          table.insert(candidates, values[i - 1])
          break
        end
      end
      return candidates
    end,
  }
end

-- list_of generator: generate a list of values from g, length scaled by size
local function gen_list_of(g: Gen, max_len?: integer): Gen
  local ml = max_len or 20
  return {
    generate = function(rng: RNG, size: integer): any
      local max_sz = math.max(0, math.floor(ml * size / 100))
      local len = rng_range(rng, 0, max_sz)
      local result: {any} = {}
      for _ = 1, len do
        table.insert(result, g.generate(rng, size))
      end
      return result
    end,
    shrink = function(v: any): {any}
      local lst = v as {any}
      if #lst == 0 then
        return {}
      end
      -- drop the last element
      local shorter: {any} = {}
      for i = 1, #lst - 1 do
        table.insert(shorter, lst[i])
      end
      return {shorter}
    end,
  }
end

-- map generator: apply fn to the output of g
local function gen_map(g: Gen, fn: function(any): any): Gen
  return {
    generate = function(rng: RNG, size: integer): any
      return fn(g.generate(rng, size))
    end,
    shrink = function(v: any): {any}
      -- shrink the underlying value then re-apply fn
      local candidates: {any} = {}
      for _, shrunk in ipairs(g.shrink(v)) do
        table.insert(candidates, fn(shrunk))
      end
      return candidates
    end,
  }
end

-- such_that generator: retry until predicate holds (max_retries attempts)
local function gen_such_that(g: Gen, pred: function(any): boolean, max_retries: integer): Gen
  local retries = max_retries or 10
  return {
    generate = function(rng: RNG, size: integer): any
      for _ = 1, retries do
        local v = g.generate(rng, size)
        if pred(v) then
          return v
        end
      end
      error("such_that: predicate not satisfied after " .. tostring(retries) .. " attempts")
    end,
    shrink = function(v: any): {any}
      local candidates: {any} = {}
      for _, c in ipairs(g.shrink(v)) do
        if pred(c) then
          table.insert(candidates, c)
        end
      end
      return candidates
    end,
  }
end

local gen: GenModule = {
  integer = gen_integer,
  boolean = gen_boolean,
  string = gen_string,
  bytes = gen_bytes,
  one_of = gen_one_of,
  list_of = gen_list_of,
  map = gen_map,
  such_that = gen_such_that,
}

-- safe_call: wrap a thunk in pcall, return (ok, errmsg)
-- Using a typed wrapper so Teal infers pcall's second return value.
local function safe_call(thunk: function()): boolean, string
  return pcall(thunk)
end

-- CheckResult: summary of a proptest run
local record CheckResult
  ok: boolean
  seed: integer
  iterations: integer
  counterexample: any
  error: string
end

-- shrink: given failing inputs, find a minimal counterexample
local function shrink_inputs(
    gens: {Gen},
    inputs: {any},
    fn: function(...: any),
    max_shrinks: integer
  ): {any}
  local best = inputs
  for _ = 1, max_shrinks do
    local found = false
    for i, g in ipairs(gens) do
      for _, candidate in ipairs(g.shrink(best[i])) do
        -- build trial with candidate substituted at position i
        local trial: {any} = {}
        for j = 1, #best do
          table.insert(trial, best[j])
        end
        trial[i] = candidate
        local trial_ok = safe_call(function()
            fn(table.unpack(trial))
          end)
        if not trial_ok then
          best = trial
          found = true
          break
        end
      end
      if found then
        break
      end
    end
    if not found then
      break
    end
  end
  return best
end

-- Seed from environment variable for reproducibility
local _fixed_seed: integer = nil
do
  local seed_env = os.getenv("PROPTEST_SEED")
  if seed_env then
    local n = math.tointeger(tonumber(seed_env))
    if n then
      _fixed_seed = n
    end
  end
end

local MAX_SIZE < const > = 100
local ITERATIONS < const > = 100
local MAX_SHRINKS < const > = 100

--- Run a property check.
--- Generates `iterations` (default 100) random inputs from `gens` and calls `fn`.
--- On failure, shrinks to a minimal counterexample and raises an error.
--- Set PROPTEST_SEED=N environment variable to replay a specific seed.
---
--- @param name string Property name (shown in output)
--- @param gens Gen|{Gen} Single generator or list of generators
--- @param fn function Property function; receives one arg per generator
local function check(name: string, gens: any, fn: function(...: any))
  -- normalise gens to a list
  local gen_list: {Gen}
  if (gens as Gen).generate then
    gen_list = {gens as Gen}
  else
    gen_list = gens as {Gen}
  end

  local seed: integer
  if _fixed_seed then
    seed = _fixed_seed
  else
    seed = rand.rand64()
  end

  local rng = new_rng(seed)

  for i = 1, ITERATIONS do
    local size = math.floor(i * MAX_SIZE / ITERATIONS)
    local inputs: {any} = {}
    for _, g in ipairs(gen_list) do
      table.insert(inputs, g.generate(rng, size))
    end

    local ok, err = safe_call(function()
        fn(table.unpack(inputs))
      end)
    if not ok then
      -- shrink to minimal counterexample
      local minimal = shrink_inputs(gen_list, inputs, fn, MAX_SHRINKS)
      local err_str = tostring(err)
      io.stderr:write(
        "FAIL " .. name .. " (seed=" .. tostring(seed) ..
        ", iter=" .. tostring(i) .. ")\n"
      )
      io.stderr:write("  counterexample: ")
      for ci, cv in ipairs(minimal) do
        if ci > 1 then
          io.stderr:write(", ")
        end
        io.stderr:write(tostring(cv))
      end
      io.stderr:write("\n")
      io.stderr:write("  error: " .. err_str .. "\n")
      error("proptest FAIL: " .. name .. " seed=" .. tostring(seed) .. " error=" .. err_str, 2)
    end
  end

  print("PASS " .. name .. " (" .. tostring(ITERATIONS) .. " iterations)")
end

local record ProptestModule
  Gen: Gen
  CheckResult: CheckResult
  gen: GenModule
  check: function(name: string, gens: any, fn: function(...: any))
end

local M: ProptestModule = {
  gen = gen,
  check = check,
}

return M
