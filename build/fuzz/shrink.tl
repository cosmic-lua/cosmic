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

  --- What a shrink found: the simplest failing draws, and how many
  --- candidates it checked to find them.
  record Shrunk
    draws: {Draw}
    --- Calls to the property's failure predicate.
    tries: integer
    --- Proposals answered without another predicate call.
    cached: integer
    improvements: integer
    --- `budget` stops at the proposal cap; `exhausted` completes the
    --- available passes, without claiming a globally minimal failure.
    reason: string
  end
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

--- The value of each draw, in order: the input to replay them.
function Shrink.values_of(draws: {Shrink.Draw}): {integer}
  local out: {integer} = {}
  for i, d in ipairs(draws) do out[i] = d.value end
  return out
end

--- The smallest failing draws found from `draws`, which must fail, and
--- how many candidates were checked. At most `max_tries` proposals are
--- considered, including cache hits, bounding work on repetitive traces.
--- @param draws {Draw} Draws whose input fails
--- @param fails Fails Whether a candidate's input still fails
--- @param max_tries integer The most candidates to check
--- @return Shrunk The simplest failing draws found, and how many
--- candidates were checked
function Shrink.shrink(draws: {Shrink.Draw}, fails: Shrink.Fails,
    max_tries: integer): Shrink.Shrunk
  local best = draws
  local tries = 0
  local proposals = 0
  local cached = 0
  local improvements = 0
  local seen: {string: boolean} = {}
  local settled: {integer: string} = {}

  local function key(values: {integer}): string
    local parts: {string} = {}
    for i, value in ipairs(values) do parts[i] = string.pack("<i8", value) end
    return table.concat(parts)
  end

  seen[key(Shrink.values_of(draws))] = true

  local function try(values: {integer}): boolean
    if proposals >= max_tries then return false end
    proposals = proposals + 1
    local name = key(values)
    -- Best only becomes simpler: a candidate already accepted or
    -- rejected cannot improve it later. Keep keys, not replay trees.
    if seen[name] then
      cached = cached + 1
      return false
    end
    seen[name] = true
    tries = tries + 1
    local failed, used = fails(values)
    if failed and simpler(used, best) then
      best = used
      improvements = improvements + 1
      return true
    end
    return false
  end

  local function cut(size: integer, limit: integer): boolean
    local changed = false
    local i = #best - size + 1
    while i >= 1 and proposals < limit do
      local values: {integer} = {}
      for j, d in ipairs(best) do
        if j < i or j >= i + size then values[#values + 1] = d.value end
      end
      if try(values) then
        changed = true
        if i > #best - size + 1 then i = #best - size + 1 end
      else
        i = i - 1
      end
    end
    return changed
  end

  local improved = true
  while improved and proposals < max_tries do
    improved = false
    -- Coarse deletions cheaply remove large stretches. Try intervening
    -- lengths only after the cheap passes stop making progress.
    local sizes: {integer: boolean} = {}
    local size = #best
    -- Repetitive deletions must leave work for reducing draw values.
    local deletion_limit = proposals + (max_tries - proposals) // 2
    while size > 0 and proposals < deletion_limit do
      if cut(size, deletion_limit) then improved = true end
      if proposals < deletion_limit then sizes[size] = true end
      size = size // 2
    end
    local i = 1
    while i <= #best and proposals < max_tries do
      local d = best[i]
      local delta = offset(d)
      if delta ~= 0 and settled[i] ~= key(Shrink.values_of(best)) then
        local count = #best
        local before = best
        local values = Shrink.values_of(best)
        values[i] = d.min
        if try(values) then
          improved = true
        else
          while #best == count and best[i].min == d.min and proposals < max_tries do
            local previous = best
            -- Probe disconnected failing regions across the full width;
            -- passing midpoints do not rule out smaller failures.
            local half = offset(best[i]) >> 1
            while half ~= 0 and #best == count and proposals < max_tries do
              values = Shrink.values_of(best)
              values[i] = d.min + half
              if try(values) then improved = true end
              half = half >> 1
            end
            -- Search below a known failure using unsigned differences.
            -- Revisit halves when this changes the high end: a different
            -- sequence can expose another disconnected failing region.
            local low = 0
            while #best == count and best[i].min == d.min and proposals < max_tries do
              local high = offset(best[i])
              if not math.ult(low, high) or high - low == 1 then break end
              local middle = low + ((high - low) >> 1)
              values = Shrink.values_of(best)
              values[i] = d.min + middle
              if try(values) then improved = true else low = middle end
            end
            if best == previous then break end
          end
        end
        -- A later draw's reduction can change this one's constraints.
        -- Reuse its completed search only while every other draw and
        -- its own range remain what they were when the search began.
        local unchanged = #best == count
        if unchanged then
          for j, old in ipairs(before) do
            local now = best[j]
            if now.min ~= old.min or now.max ~= old.max or (j ~= i and now.value ~= old.value) then
              unchanged = false
              break
            end
          end
        end
        if unchanged then settled[i] = key(Shrink.values_of(best)) end
      end
      i = i + 1
    end
    if not improved then
      for length = #best, 1, -1 do
        if proposals >= max_tries then break end
        if not sizes[length] and cut(length, max_tries) then
          improved = true
          break
        end
      end
    end
  end
  return { draws = best, tries = tries, cached = cached, improvements = improvements,
    reason = proposals >= max_tries and "budget" or "exhausted" }
end

return Shrink
