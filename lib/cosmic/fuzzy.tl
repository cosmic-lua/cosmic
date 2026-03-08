--- Fuzzy string matching utilities.

--- Compute Levenshtein distance between two strings.
--- Uses a two-row algorithm with O(min(n,m)) memory and string.byte
--- for fast character comparison.
--- @param a string First string
--- @param b string Second string
--- @return integer Edit distance
local function levenshtein(a: string, b: string): integer
  local la = #a
  local lb = #b
  if la == 0 then return lb end
  if lb == 0 then return la end
  if a == b then return 0 end

  -- swap so that b is always the shorter string (fewer columns)
  if la < lb then
    a, b = b, a
    la, lb = lb, la
  end

  -- two-row algorithm: prev and curr, each of length lb+1
  local prev: {integer} = {}
  local curr: {integer} = {}
  for j = 0, lb do
    prev[j] = j
  end

  for i = 1, la do
    curr[0] = i
    local ai = a:byte(i)
    for j = 1, lb do
      local cost = ai == b:byte(j) and 0 or 1
      local del = prev[j] + 1
      local ins = curr[j - 1] + 1
      local sub = prev[j - 1] + cost
      -- inline min of three values
      if del < ins then
        curr[j] = del < sub and del or sub
      else
        curr[j] = ins < sub and ins or sub
      end
    end
    prev, curr = curr, prev
  end

  return prev[lb]
end

--- Find similar strings from a list using Levenshtein distance.
--- @param query string The search query
--- @param candidates {string} List of strings to match against
--- @param max_distance integer Maximum edit distance to consider (default 3)
--- @return {string} List of similar values, sorted by distance then alphabetically
local function find_similar(query: string, candidates: {string}, max_distance?: integer): {string}
  max_distance = max_distance or 3
  local results: {{string, integer}} = {} -- {value, distance}
  local seen: {string: boolean} = {}

  local query_lower = query:lower()
  for _, candidate in ipairs(candidates) do
    if not seen[candidate] then
      local dist = levenshtein(query_lower, candidate:lower())
      if dist <= max_distance then
        seen[candidate] = true
        table.insert(results, {candidate, dist})
      end
    end
  end

  -- Sort by distance, then alphabetically
  table.sort(results, function(a: {string, integer}, b: {string, integer}): boolean
      if a[2] ~= b[2] then
        return a[2] < b[2]
      end
      return a[1] < b[1]
    end)

  -- Extract just the names
  local names: {string} = {}
  for _, r in ipairs(results) do
    table.insert(names, r[1])
  end

  return names
end

local record FuzzyModule
  levenshtein: function(a: string, b: string): integer
  find_similar: function(query: string, candidates: {string}, max_distance?: integer): {string}
end

local M: FuzzyModule = {
  levenshtein = levenshtein,
  find_similar = find_similar,
}

return M
