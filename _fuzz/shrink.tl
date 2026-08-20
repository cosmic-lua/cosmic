--- Shrinks a failing draw sequence toward a smaller one that still
--- fails, so a fuzz failure reports a minimized input instead of the
--- raw generated one. Internal to `_fuzz`, same as source.tl -- no
--- shrinking guarantee (global minimum, or even "same failure cause")
--- is made, so this is not ready to be `cosmic.fuzz`'s public surface.

local source = require("_fuzz.source")

--- Every still_fails call -- structural or value -- counts one
--- against this budget, threaded as a single running total through
--- both shrink passes. Chosen above the costliest generator in the
--- tree today: _fuzz/compress_fuzz_test.tl's round-trip generator
--- draws up to 4097 values per input (ROUND_TRIP_MAX_LEN = 4096).
local MAX_SHRINK_ATTEMPTS = 20000

--- The two closures shrink needs from a fuzz property. A narrower
--- type than driver.Options so this module never requires
--- _fuzz.driver -- driver.tl requires shrink.tl, and a require back
--- the other way would be circular.
local record Property
  gen: function(src: source.Recorder): string
  check: function(input: string): boolean, string
end

--- Replay `draws` through `prop.gen` and check the result.
--- A replay that runs out of draws, or hits a draw of the wrong kind
--- (the edited sequence changed the generator's control flow), is an
--- INVALID candidate, not a failing one, and reports false without
--- calling `prop.check` at all. A candidate that reaches `check` is
--- "still failing" on either a false return or a thrown error --
--- shrinking does not distinguish which invariant broke.
--- @param prop Property The property under test
--- @param draws {source.Draw} The candidate draw sequence
--- @return boolean True when the candidate still fails
local function still_fails(prop: Property, draws: {source.Draw}): boolean
  local rec = source.replay(draws)
  local ok_gen, input = pcall(prop.gen, rec)
  if not ok_gen then
    return false
  end
  local ok_check, held = pcall(prop.check, input)
  if not ok_check then
    return true
  end
  return not held
end

--- Copy a draw list, so a candidate can be edited without mutating
--- the sequence it was derived from.
--- @param draws {source.Draw} The sequence to copy
--- @return {source.Draw} A shallow copy
local function copy_draws(draws: {source.Draw}): {source.Draw}
  local out: {source.Draw} = {}
  for i, d in ipairs(draws) do
    out[i] = d
  end
  return out
end

--- ddmin (Zeller) chunk deletion: try removing each contiguous chunk
--- at the current granularity, keep the first removal that still
--- fails, and coarsen or refine the granularity as chunk deletion
--- succeeds or exhausts itself.
--- @param prop Property The property under test
--- @param draws {source.Draw} The draw sequence to shrink
--- @param attempts integer The running attempt count
--- @return {source.Draw} The structurally-minimized draws
--- @return integer The updated attempt count
local function shrink_structure(
    prop: Property, draws: {source.Draw}, attempts: integer
  ): {source.Draw}, integer
  local current = draws
  local granularity = 2
  while #current >= 1 and granularity <= #current and attempts < MAX_SHRINK_ATTEMPTS do
    local chunk_size = (#current + granularity - 1) // granularity
    local reduced = false
    local start = 1
    while start <= #current and attempts < MAX_SHRINK_ATTEMPTS do
      local candidate: {source.Draw} = {}
      for i, d in ipairs(current) do
        if i < start or i >= start + chunk_size then
          candidate[#candidate + 1] = d
        end
      end
      attempts = attempts + 1
      if #candidate < #current and still_fails(prop, candidate) then
        current = candidate
        granularity = math.max(granularity - 1, 2)
        reduced = true
        break
      end
      start = start + chunk_size
    end
    if not reduced then
      if granularity >= #current then
        break
      end
      granularity = granularity * 2
    end
  end
  return current, attempts
end

--- Binary-search an int draw toward its `lo` bound for the smallest
--- value that still fails. Assumes the failure is monotonic in this
--- value, which need not hold for an arbitrary property -- a draw
--- the search cannot shrink keeps its original value.
--- @param prop Property The property under test
--- @param draws {source.Draw} The current draw sequence
--- @param idx integer The index of the int draw to shrink
--- @param attempts integer The running attempt count
--- @return integer The smallest value the search found still failing
--- @return integer The updated attempt count
local function shrink_int_draw(
    prop: Property, draws: {source.Draw}, idx: integer, attempts: integer
  ): integer, integer
  local d = draws[idx]
  local lo = d.lo
  local hi = d.ivalue
  local best = hi
  while lo < hi and attempts < MAX_SHRINK_ATTEMPTS do
    local mid = lo + (hi - lo) // 2
    local candidate = copy_draws(draws)
    candidate[idx] = {kind = "int", lo = d.lo, hi = d.hi, ivalue = mid}
    attempts = attempts + 1
    if still_fails(prop, candidate) then
      best = mid
      hi = mid
    else
      lo = mid + 1
    end
  end
  return best, attempts
end

--- Bisect a float draw toward 0.0 for a smaller value that still
--- fails: try 0.0 outright, then bisect between 0.0 and the current
--- value for up to 20 steps (or until the attempt budget runs out).
--- @param prop Property The property under test
--- @param draws {source.Draw} The current draw sequence
--- @param idx integer The index of the float draw to shrink
--- @param attempts integer The running attempt count
--- @return number The smallest-magnitude value the search found still failing
--- @return integer The updated attempt count
local function shrink_float_draw(
    prop: Property, draws: {source.Draw}, idx: integer, attempts: integer
  ): number, integer
  local d = draws[idx]
  local original = d.fvalue
  local best = original
  if attempts < MAX_SHRINK_ATTEMPTS then
    local zeroed = copy_draws(draws)
    zeroed[idx] = {kind = "float", fvalue = 0.0}
    attempts = attempts + 1
    if still_fails(prop, zeroed) then
      return 0.0, attempts
    end
  end
  local lo, hi = 0.0, original
  local steps = 0
  while steps < 20 and attempts < MAX_SHRINK_ATTEMPTS do
    local mid = lo + (hi - lo) / 2
    local candidate = copy_draws(draws)
    candidate[idx] = {kind = "float", fvalue = mid}
    attempts = attempts + 1
    steps = steps + 1
    if still_fails(prop, candidate) then
      best = mid
      hi = mid
    else
      lo = mid
    end
  end
  return best, attempts
end

--- One left-to-right pass shrinking every int/float draw toward its
--- simplest failing value, greedily keeping each shrink before moving
--- to the next draw.
--- @param prop Property The property under test
--- @param draws {source.Draw} The structurally-minimized draws
--- @param attempts integer The running attempt count
--- @return {source.Draw} The value-minimized draws
--- @return integer The updated attempt count
local function shrink_values(
    prop: Property, draws: {source.Draw}, attempts: integer
  ): {source.Draw}, integer
  local current = copy_draws(draws)
  for idx, d in ipairs(current) do
    if attempts >= MAX_SHRINK_ATTEMPTS then
      break
    end
    if d.kind == "int" then
      local shrunk: integer
      shrunk, attempts = shrink_int_draw(prop, current, idx, attempts)
      current[idx] = {kind = "int", lo = d.lo, hi = d.hi, ivalue = shrunk}
    elseif d.kind == "float" then
      local shrunk: number
      shrunk, attempts = shrink_float_draw(prop, current, idx, attempts)
      current[idx] = {kind = "float", fvalue = shrunk}
    end
  end
  return current, attempts
end

--- Shrink a failing draw sequence: structural deletion first, then a
--- value-minimization pass over what remains. Stops the moment
--- MAX_SHRINK_ATTEMPTS is spent and returns the best draws found so
--- far -- it never throws for running out of budget.
--- @param gen function(src: source.Recorder): string The property's generator
--- @param check function(input: string): boolean, string The property's check
--- @param draws {source.Draw} The originally-recorded failing draws
--- @return {source.Draw} The minimized draws
--- @return integer How many still_fails calls the search spent
local function shrink(
    gen: function(src: source.Recorder): string,
    check: function(input: string): boolean, string,
    draws: {source.Draw}
  ): {source.Draw}, integer
  local prop: Property = {gen = gen, check = check}
  local structural, attempts = shrink_structure(prop, draws, 0)
  return shrink_values(prop, structural, attempts)
end

local record ShrinkModule
  shrink: function(
  gen: function(src: source.Recorder): string,
  check: function(input: string): boolean, string,
  draws: {source.Draw}
): {source.Draw}, integer
end

local M: ShrinkModule = {
  shrink = shrink,
}

return M
