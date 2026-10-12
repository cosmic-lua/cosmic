--- How [`build.shards`] shares modules among the processes that compile
--- them. What a plan must hold for any build is that each module to
--- compile is compiled once, after what it imports, and that the plan
--- does not depend on the order a table happened to list things.

local shards = require("build.shards")

--- A build of `layers` layers of `width` modules, each importing every
--- module of the layer below, each `size` long. Imports come first.
local function layered(layers: integer, width: integer, size: integer): {shards.Item}
  local order: {shards.Item} = {}
  for layer = 1, layers do
    for column = 1, width do
      local requires: {string} = {}
      if layer > 1 then
        for below = 1, width do requires[#requires + 1] = "m" .. (layer - 1) .. "_" .. below end
      end
      order[#order + 1] = { path = "m" .. layer .. "_" .. column, requires = requires, size = size }
    end
  end
  return order
end

local function everything(order: {shards.Item}): {string:boolean}
  local wanted: {string:boolean} = {}
  for _, item in ipairs(order) do wanted[item.path] = true end
  return wanted
end

--- The shard each path of `plan` is in, and how often each is listed.
local function placed(plan: {{string}}): {string:integer}, {string:integer}
  local shard_of: {string:integer} = {}
  local times: {string:integer} = {}
  for shard, paths in ipairs(plan) do
    for _, path in ipairs(paths) do
      shard_of[path] = shard
      times[path] = (times[path] or 0) + 1
    end
  end
  return shard_of, times
end

local function test_every_wanted_module_is_in_exactly_one_shard()
  local order = layered(4, 6, 2000)
  local wanted = everything(order)
  for count = 1, 5 do
    local plan = shards.plan(order, wanted, count).shards
    local _, times = placed(plan)
    for path in pairs(wanted) do
      assert(times[path] == 1, path .. " listed " .. tostring(times[path]) .. " times for " .. count)
    end
    assert(#plan <= count and #plan >= 1, "shards: " .. #plan)
    for _, paths in ipairs(plan) do assert(#paths > 0, "an empty shard") end
  end
end

local function test_a_shard_lists_modules_in_the_order_given()
  local order = layered(5, 4, 1500)
  local position: {string:integer} = {}
  for at, item in ipairs(order) do position[item.path] = at end
  for _, paths in ipairs(shards.plan(order, everything(order), 3).shards) do
    for at = 2, #paths do
      assert(position[paths[at - 1]] < position[paths[at]], paths[at - 1] .. " after " .. paths[at])
    end
  end
end

local function test_a_module_nobody_wants_is_in_no_shard()
  local order = layered(3, 3, 1000)
  local wanted: {string:boolean} = { m3_1 = true, m2_2 = true }
  local _, times = placed(shards.plan(order, wanted, 2).shards)
  for _, item in ipairs(order) do
    assert(times[item.path] == (wanted[item.path] and 1 or nil), item.path)
  end
end

local function test_the_plan_does_not_depend_on_how_the_wanted_set_was_built()
  local order = layered(4, 5, 1700)
  local forward: {string:boolean} = {}
  local backward: {string:boolean} = {}
  for at = 1, #order do forward[order[at].path] = true end
  for at = #order, 1, -1 do backward[order[at].path] = true end
  local one = shards.plan(order, forward, 3).shards
  local other = shards.plan(order, backward, 3).shards
  assert(#one == #other)
  for shard = 1, #one do
    assert(table.concat(one[shard], ",") == table.concat(other[shard], ","), "shard " .. shard)
  end
end

--- Two sets of modules that share nothing, each a large module that
--- five small ones import.
local function two_clusters(): {shards.Item}
  local order: {shards.Item} = {}
  for _, name in ipairs({ "a", "b" }) do
    order[#order + 1] = { path = name .. "_base", requires = {}, size = 60000 }
    for leaf = 1, 5 do
      order[#order + 1] = { path = name .. "_leaf" .. leaf, requires = { name .. "_base" }, size = 3000 }
    end
  end
  return order
end

local function test_modules_that_share_imports_share_a_shard()
  -- Checking a cluster's large module in both shards would double its
  -- cost: its leaves belong together.
  local order = two_clusters()
  local plan = shards.plan(order, everything(order), 2).shards
  assert(#plan == 2, "shards: " .. #plan)
  local shard_of = placed(plan)
  for leaf = 2, 5 do
    assert(shard_of["a_leaf" .. leaf] == shard_of["a_leaf1"], "a_leaf" .. leaf)
    assert(shard_of["b_leaf" .. leaf] == shard_of["b_leaf1"], "b_leaf" .. leaf)
  end
  assert(shard_of.a_leaf1 ~= shard_of.b_leaf1, "both clusters went to one shard")
end

local function test_best_takes_one_shard_when_more_do_not_pay()
  -- Each module imports the one before: whoever compiles the last
  -- checks all of them, so every process added repeats the chain.
  local order: {shards.Item} = {}
  for at = 1, 12 do
    order[at] = { path = "link" .. at, requires = at > 1 and { "link" .. (at - 1) } or {}, size = 4000 }
  end
  local plan = shards.best(order, everything(order), 4)
  assert(#plan == 1, "shards: " .. #plan)
  assert(#plan[1] == 12)
end

local function test_best_takes_more_shards_when_they_pay()
  -- Independent modules share nothing, so every process halves the work.
  local order: {shards.Item} = {}
  for at = 1, 40 do order[at] = { path = "alone" .. at, requires = {}, size = 8000 } end
  local plan = shards.best(order, everything(order), 4)
  assert(#plan >= 3, "shards: " .. #plan)
end

local function test_nothing_wanted_is_no_shard()
  local order = layered(2, 2, 100)
  assert(#shards.plan(order, {}, 3).shards == 0)
  assert(#shards.best(order, {}, 3) == 0)
end
