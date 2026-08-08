--- Fuzzy string matching utilities.
--- Approximate (edit-distance) matching. For exact plain-text search
--- see cosmic.string; for pattern-based matching see cosmic.re.

--- Compute the edit distance between two strings (Levenshtein).
--- Uses a two-row algorithm with O(min(n,m)) memory and string.byte
--- for fast character comparison.
--- @param a string First string
--- @param b string Second string
--- @return integer Edit distance
local function distance(a: string, b: string): integer
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

--- One similar candidate: the value and the edit distance the search
--- already computed for it (previously thrown away, which forced the
--- one caller wanting a ranked score to re-run the DP itself).
local record Match
  value: string
  distance: integer
end

--- Options for find_similar.
local record Options
  --- Maximum edit distance to consider (default 3).
  max_distance: integer
  --- Keep at most this many matches (default all).
  limit: integer
end

--- Find similar strings from a list by edit distance (case-insensitive,
--- deduplicated on the lowercased form).
--- @param query string The search query
--- @param candidates {string} List of strings to match against
--- @param opts Options? max_distance (default 3), limit (default all)
--- @return {Match} Matches with their distances, sorted by distance then value
local function find_similar(query: string, candidates: {string}, opts?: Options): {Match}
  local max_distance = 3
  local limit: integer = nil
  if opts then
    if opts.max_distance then max_distance = opts.max_distance end
    limit = opts.limit
  end
  local results: {Match} = {}
  local seen: {string: boolean} = {}

  local query_lower = query:lower()
  for _, candidate in ipairs(candidates) do
    -- Key seen on the lowercased form so that "Foo" and "foo" are treated as
    -- the same candidate (matching is already case-insensitive).
    local candidate_lower = candidate:lower()
    if not seen[candidate_lower] then
      -- Length-difference gate: the edit distance between two strings is at
      -- least the difference in their lengths, so a candidate whose length
      -- differs from the query by more than max_distance can never qualify.
      -- Skipping it avoids the O(n*m) DP with no change to the result set.
      if math.abs(#query_lower - #candidate_lower) <= max_distance then
        local dist = distance(query_lower, candidate_lower)
        if dist <= max_distance then
          seen[candidate_lower] = true
          table.insert(results, {value = candidate, distance = dist})
        end
      end
    end
  end

  -- Sort by distance, then by value
  table.sort(results, function(a: Match, b: Match): boolean
      if a.distance ~= b.distance then
        return a.distance < b.distance
      end
      return a.value < b.value
    end)

  if limit and #results > limit then
    local trimmed: {Match} = {}
    for i = 1, limit do
      trimmed[i] = results[i]
    end
    return trimmed
  end
  return results
end

local record FuzzyModule
  type Match = Match
  type Options = Options
  distance: function(a: string, b: string): integer
  find_similar: function(query: string, candidates: {string}, opts?: Options): {Match}
end

local M: FuzzyModule = {
  distance = distance,
  find_similar = find_similar,
}

return M
