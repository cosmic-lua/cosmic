--- Fuzzy string matching utilities.

--- Compute Levenshtein distance between two strings.
--- @param a string First string
--- @param b string Second string
--- @return integer Edit distance
local function levenshtein(a: string, b: string): integer
  if #a == 0 then return #b end
  if #b == 0 then return #a end
  if a == b then return 0 end

  -- Create distance matrix
  local matrix: {{integer}} = {}
  for i = 0, #a do
    matrix[i] = {}
    matrix[i][0] = i
  end
  for j = 0, #b do
    matrix[0][j] = j
  end

  -- Fill in the rest of the matrix
  for i = 1, #a do
    for j = 1, #b do
      local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
      matrix[i][j] = math.min(
        matrix[i-1][j] + 1,      -- deletion
        matrix[i][j-1] + 1,      -- insertion
        matrix[i-1][j-1] + cost  -- substitution
      )
    end
  end

  return matrix[#a][#b]
end

--- Find similar strings from a list using Levenshtein distance.
--- @param query string The search query
--- @param candidates {string} List of strings to match against
--- @param max_distance integer Maximum edit distance to consider (default 3)
--- @return {string} List of similar values, sorted by distance then alphabetically
local function find_similar(query: string, candidates: {string}, max_distance?: integer): {string}
  max_distance = max_distance or 3
  local results: {{string, integer}} = {}  -- {value, distance}
  local seen: {string:boolean} = {}

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
