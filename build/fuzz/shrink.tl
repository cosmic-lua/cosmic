--- Shrinking a failing input by its draws. An input is what a generator
--- built from a list of integer draws, so a smaller list -- fewer draws,
--- or the same draws nearer the low end of each one's range -- builds a
--- simpler input. `shrink` cuts runs of draws and lowers single ones for
--- as long as the input they build still fails, keeping only a candidate
--- strictly simpler than the best so far, so it always ends.

local record Shrink
  --- One integer a generator drew, and the range it asked for.
  record Draw
    min: integer
    max: integer
    value: integer
  end

  --- Whether the input `values` build still fails, and the draws that
  --- building it actually made: a replay clamps a value out of range and
  --- supplies the low end for a draw past the list's end.
  type Fails = function(values: {integer}): boolean, {Draw}
end

--- How far `d` sits above its range's low end, read as unsigned.
local function offset(d: Shrink.Draw): integer
  return d.value - d.min
end

--- Whether `a` is strictly simpler than `b`: fewer draws, or as many with
--- the first that differs lower in its range.
local function simpler(a: {Shrink.Draw}, b: {Shrink.Draw}): boolean
  if #a ~= #b then return #a < #b end
  for i = 1, #a do
    local x, y = offset(a[i]), offset(b[i])
    if x ~= y then return math.ult(x, y) end
  end
  return false
end

local function values_of(draws: {Shrink.Draw}): {integer}
  local out: {integer} = {}
  for i, d in ipairs(draws) do out[i] = d.value end
  return out
end

--- The smallest failing draws found from `draws`, which must fail, and
--- how many candidates were checked, at most `max_tries`.
--- @param draws {Draw} Draws whose input fails
--- @param fails Fails Whether a candidate's input still fails
--- @param max_tries integer The most candidates to check
--- @return {Draw} The simplest failing draws found
--- @return integer How many candidates were checked
function Shrink.shrink(draws: {Shrink.Draw}, fails: Shrink.Fails,
    max_tries: integer): {Shrink.Draw}, integer
  local best = draws
  local tries = 0

  local function try(values: {integer}): boolean
    if tries >= max_tries then return false end
    tries = tries + 1
    local failed, used = fails(values)
    if failed and simpler(used, best) then
      best = used
      return true
    end
    return false
  end

  local improved = true
  while improved and tries < max_tries do
    improved = false
    -- Cut runs of draws, longest first, from the end backward.
    for _, size in ipairs({ 8, 4, 2, 1 }) do
      local i = #best - size + 1
      while i >= 1 and tries < max_tries do
        local values = values_of(best)
        for _ = 1, size do table.remove(values, i) end
        if try(values) then
          improved = true
          if i > #best - size + 1 then i = #best - size + 1 end
        else
          i = i - 1
        end
      end
    end
    -- Lower each draw: to its low end, else by halves, else by one.
    local i = 1
    while i <= #best and tries < max_tries do
      local d = best[i]
      local delta = offset(d)
      if delta ~= 0 then
        local values = values_of(best)
        values[i] = d.min
        if try(values) then
          improved = true
        else
          local half = delta >> 1
          while half ~= 0 and tries < max_tries do
            values = values_of(best)
            values[i] = d.min + half
            if not try(values) then break end
            improved = true
            half = half >> 1
          end
          if i <= #best and offset(best[i]) ~= 0 then
            values = values_of(best)
            values[i] = best[i].value - 1
            if try(values) then improved = true end
          end
        end
      end
      i = i + 1
    end
  end
  return best, tries
end

return Shrink
