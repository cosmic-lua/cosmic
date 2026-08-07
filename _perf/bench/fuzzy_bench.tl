--- Fuzzy-matching scenarios: cosmic.fuzzy.find_similar over a namespace.
--- Models a "did you mean?" / autocomplete lookup: one short query matched
--- against a large candidate set. The check pins the exact match set so a
--- faster-but-wrong matcher (e.g. one that wrongly prunes candidates) fails
--- instead of winning.

local fuzzy = require("cosmic.fuzzy")
local pt = require("_perf.perf_types")

local QUERY = "instal"

--- Build a candidate namespace with one true match and a mix of non-matches.
--- Half the non-matches share the query's length (6) so they run the full
--- edit-distance DP; the other half are much longer, the case a
--- length-difference gate can reject without the DP. None of the decoys are
--- within edit distance 3 of the query, so the match set is exactly
--- {"install"} regardless of any such gate.
--- @return {string} The candidate list
local function build_candidates(): {string}
  local c: {string} = {"install"}
  for i = 1, 128 do
    -- length 6, same as the query, content-far: not gated, no match.
    c[#c + 1] = string.format("qx%04d", i)
    -- length 11, far from the query length: a length gate can skip these.
    c[#c + 1] = string.format("symbol_%04d", i)
  end
  return c
end

local CANDIDATES = build_candidates()

local function scenarios(): {pt.Scenario}, string
  return {
    {
      name = "fuzzy_find_similar",
      fn = function(_: any): any
        return fuzzy.find_similar(QUERY, CANDIDATES)
      end,
      check = function(_: any, res: any): boolean, string
        local matches = res as {fuzzy.Match} -- cast: from any
        if matches == nil or #matches ~= 1 then
          return false, "expected exactly one match, got " ..
          tostring(matches and #matches)
        end
        if matches[1].value ~= "install" then
          return false, "wrong match: " .. tostring(matches[1].value)
        end
        if matches[1].distance ~= 1 then
          return false, "wrong distance: " .. tostring(matches[1].distance)
        end
        return true
      end,
    },
  }
end

local function cleanup()
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
