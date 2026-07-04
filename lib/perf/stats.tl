--- Basic statistics over benchmark samples.
--- All functions return 0 for an empty input list.

--- Return a sorted copy of the input list.
--- @param values {number} The values to sort
--- @return {number} A new, ascending-sorted list
local function sorted(values: {number}): {number}
  local copy: {number} = {}
  for i, v in ipairs(values) do
    copy[i] = v
  end
  table.sort(copy)
  return copy
end

--- Smallest value in the list.
--- @param values {number} The values
--- @return number The minimum, or 0 if empty
local function min(values: {number}): number
  if #values == 0 then
    return 0
  end
  local m = values[1]
  for _, v in ipairs(values) do
    if v < m then
      m = v
    end
  end
  return m
end

--- Largest value in the list.
--- @param values {number} The values
--- @return number The maximum, or 0 if empty
local function max(values: {number}): number
  if #values == 0 then
    return 0
  end
  local m = values[1]
  for _, v in ipairs(values) do
    if v > m then
      m = v
    end
  end
  return m
end

--- Arithmetic mean of the list.
--- @param values {number} The values
--- @return number The mean, or 0 if empty
local function mean(values: {number}): number
  if #values == 0 then
    return 0
  end
  local total = 0.0
  for _, v in ipairs(values) do
    total = total + v
  end
  return total / #values
end

--- Median of the list (midpoint of the two middle values for even counts).
--- @param values {number} The values
--- @return number The median, or 0 if empty
local function median(values: {number}): number
  local n = #values
  if n == 0 then
    return 0
  end
  local s = sorted(values)
  local mid = n // 2
  if n % 2 == 1 then
    return s[mid + 1]
  end
  return (s[mid] + s[mid + 1]) / 2
end

--- Sample standard deviation of the list.
--- @param values {number} The values
--- @return number The standard deviation, or 0 for fewer than two values
local function stddev(values: {number}): number
  local n = #values
  if n < 2 then
    return 0
  end
  local m = mean(values)
  local sum_sq = 0.0
  for _, v in ipairs(values) do
    local d = v - m
    sum_sq = sum_sq + d * d
  end
  return math.sqrt(sum_sq / (n - 1))
end

--- Spread of the samples as a percentage of the median:
--- (max - min) / median * 100. Used as the noise bar when comparing runs.
--- @param values {number} The values
--- @return number The spread percentage, or 0 if empty or median is 0
local function spread_pct(values: {number}): number
  local med = median(values)
  if med == 0 then
    return 0
  end
  return (max(values) - min(values)) / med * 100.0
end

local record stats
  sorted: function(values: {number}): {number}
  min: function(values: {number}): number
  max: function(values: {number}): number
  mean: function(values: {number}): number
  median: function(values: {number}): number
  stddev: function(values: {number}): number
  spread_pct: function(values: {number}): number
end

local M: stats = {
  sorted = sorted,
  min = min,
  max = max,
  mean = mean,
  median = median,
  stddev = stddev,
  spread_pct = spread_pct,
}

return M
