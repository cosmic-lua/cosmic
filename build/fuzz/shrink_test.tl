local Shrink = require("build.fuzz.shrink")

local function scalar(value: integer, least: integer, most: integer): {Shrink.Draw}
  return { { min = least, max = most, value = value } }
end

local function test_threshold_search_is_logarithmic()
  local checks = 0
  local function fails(values: {integer}): boolean, {Shrink.Draw}
    checks = checks + 1
    local value = values[1] or 0
    return value >= 600000000, scalar(value, 0, 1000000000)
  end
  local result = Shrink.shrink(scalar(1000000000, 0, 1000000000), fails, 2000)
  assert(result.draws[1].value == 600000000)
  assert(checks == result.tries and checks < 200, tostring(checks))
  assert(result.reason == "exhausted")
  assert(result.cached > 0 and result.improvements > 0)
end

local function test_signed_integer_extremes_are_exact()
  for _, threshold in ipairs({ math.mininteger + 17, -1, 0, math.maxinteger - 17 }) do
    local function fails(values: {integer}): boolean, {Shrink.Draw}
      local value = values[1] or math.mininteger
      return value >= threshold, scalar(value, math.mininteger, math.maxinteger)
    end
    local result = Shrink.shrink(scalar(math.maxinteger, math.mininteger, math.maxinteger), fails, 2000)
    assert(result.draws[1].value == threshold, tostring(result.draws[1].value))
    assert(result.tries < 300, tostring(result.tries))
    assert(result.reason == "exhausted")
  end
end

local function test_nonmonotonic_failure_survives_a_passing_midpoint()
  local function fails(values: {integer}): boolean, {Shrink.Draw}
    local value = values[1] or 0
    return value == 3 or value >= 90, scalar(value, 0, 100)
  end
  local result = Shrink.shrink(scalar(100, 0, 100), fails, 2000)
  assert(result.draws[1].value == 3)
  assert(result.reason == "exhausted")
end

local function test_deletion_removes_an_indivisible_twelve_draw_block()
  local draws: {Shrink.Draw} = {}
  for i = 1, 14 do
    local value = i == 1 and 101 or i == 14 and 102 or 7
    draws[i] = { min = value, max = value, value = value }
  end
  local function fails(values: {integer}): boolean, {Shrink.Draw}
    local used: {Shrink.Draw} = {}
    for i, value in ipairs(values) do used[i] = { min = value, max = value, value = value } end
    return (#values == 2 or #values == 14) and values[1] == 101 and values[#values] == 102, used
  end
  local result = Shrink.shrink(draws, fails, 2000)
  assert(#result.draws == 2)
  assert(result.draws[1].value == 101 and result.draws[2].value == 102)
end

local function test_candidates_are_checked_once_per_shrink()
  for _ = 1, 2 do
    local seen: {string: boolean} = {}
    local checks = 0
    local function fails(values: {integer}): boolean, {Shrink.Draw}
      local name = values[1] and tostring(values[1]) or "empty"
      assert(not seen[name], "duplicate check: " .. name)
      seen[name] = true
      checks = checks + 1
      local value = values[1] or 0
      return value >= 70, scalar(value, 0, 100)
    end
    local result = Shrink.shrink(scalar(100, 0, 100), fails, 2000)
    assert(result.draws[1].value == 70)
    assert(checks == result.tries and result.cached > 0)
  end
end

local function test_budget_and_completion_are_distinct()
  local function fails(values: {integer}): boolean, {Shrink.Draw}
    local value = values[1] or 0
    return value > 0, scalar(value, 0, 100)
  end
  for _, budget in ipairs({ 0, 1, 3 }) do
    local result = Shrink.shrink(scalar(100, 0, 100), fails, budget)
    assert(result.reason == "budget" and result.tries + result.cached == budget)
    assert(result.draws[1].value > 0)
  end
  local empty = Shrink.shrink({}, fails, 3)
  assert(empty.reason == "exhausted" and empty.tries == 0 and empty.improvements == 0)
end

local function test_replay_cannot_grow_the_best_failure()
  local function fails(_values: {integer}): boolean, {Shrink.Draw}
    return true, { { min = 0, max = 10, value = 0 }, { min = 0, max = 10, value = 0 } }
  end
  local result = Shrink.shrink(scalar(10, 0, 10), fails, 2000)
  assert(#result.draws == 1 and result.draws[1].value == 10)
  assert(result.improvements == 0 and result.reason == "exhausted")
end

local function test_repetitive_replays_bound_proposals_too()
  local draws: {Shrink.Draw} = {}
  for i = 1, 128 do draws[i] = { min = 0, max = 0, value = 0 } end
  local function fails(_values: {integer}): boolean, {Shrink.Draw}
    return true, draws
  end
  local result = Shrink.shrink(draws, fails, 100)
  assert(result.reason == "budget")
  assert(result.tries + result.cached == 100)
  assert(result.cached > 0 and result.improvements == 0)
end

local function test_revisit_halves_after_the_interval_changes()
  local function fails(values: {integer}): boolean, {Shrink.Draw}
    local value = values[1] or 0
    return value == 4 or value == 68 or value == 75 or value == 100, scalar(value, 0, 100)
  end
  local result = Shrink.shrink(scalar(100, 0, 100), fails, 2000)
  assert(result.draws[1].value == 4 and result.reason == "exhausted")
end

local function test_duplicate_deletions_cannot_starve_integer_reduction()
  local function fails(values: {integer}): boolean, {Shrink.Draw}
    local used: {Shrink.Draw} = {}
    for i = 1, 1024 do used[i] = { min = 0, max = 100, value = values[i] or 0 } end
    return used[1].value >= 60, used
  end
  local _, draws = fails({ 100 })
  local result = Shrink.shrink(draws, fails, 2000)
  assert(result.draws[1].value == 60)
  assert(result.tries + result.cached <= 2000)
end

local function test_revisit_interval_even_when_half_probes_pass()
  local function fails(values: {integer}): boolean, {Shrink.Draw}
    local value = values[1] or 0
    return value == 90 or value == 96 or value == 100, scalar(value, 0, 100)
  end
  local result = Shrink.shrink(scalar(100, 0, 100), fails, 2000)
  assert(result.draws[1].value == 90 and result.reason == "exhausted")
end

local function test_full_width_halves_find_a_small_failure_island()
  local function fails(values: {integer}): boolean, {Shrink.Draw}
    local value = values[1] or 0
    return value == 3 or value >= 600000000, scalar(value, 0, 1000000000)
  end
  local result = Shrink.shrink(scalar(1000000000, 0, 1000000000), fails, 2000)
  assert(result.draws[1].value == 3 and result.reason == "exhausted")
end

-- Only the complete middle object can be deleted. Its size and position
-- are deliberately absent from the reducer's coarse chunk schedule.
local function test_structural_deletion_preserves_the_following_object()
  local function trace(values: {integer}): {Shrink.Draw}
    local out: {Shrink.Draw} = {}
    for i, value in ipairs(values) do out[i] = { min = 0, max = 100, value = value } end
    if #out == 19 then out[16].spans = { { name = "middle", first = 4, last = 16 } } end
    return out
  end
  local values: {integer} = { 11, 22, 33 }
  for _ = 1, 13 do values[#values + 1] = 99 end
  values[17], values[18], values[19] = 44, 55, 66
  local result = Shrink.shrink(trace(values), function(candidate: {integer}): boolean, {Shrink.Draw}
    local kept = table.concat(candidate, ",")
    return kept == table.concat(values, ",") or kept == "11,22,33,44,55,66", trace(candidate)
  end, 2)
  assert(table.concat(Shrink.values_of(result.draws), ",") == "11,22,33,44,55,66")
end
