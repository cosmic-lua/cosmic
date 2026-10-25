--- How a build's modules are shared among the processes that compile
--- them.
---
--- The checker's types cannot leave a process, so a process that
--- compiles a module checks everything the module imports too, unless
--- it compiled that already. A shard is the modules one process
--- compiles; the cost of a shard is the size of its modules and of
--- their whole import closure. [`shards.plan`] chooses shards that
--- balance that cost and share closures, so a module's imports are
--- checked in few processes.
---
--- The plan is a function of the modules' paths, imports and sizes and
--- of the count, and of nothing else. A module compiles to the same Lua
--- in whichever shard it lands, so the plan decides speed alone.

local record shards
  --- What a plan answers.
  record Plan
    --- Each shard's paths, in the order the modules were given.
    shards: {{string}}
    --- The load of the heaviest shard, in the plan's own units, which
    --- only compares plans of the same modules.
    heaviest: integer
  end

  --- What the plan needs of a module.
  record Item
    path: string
    --- The import paths the module requires, among others.
    requires: {string}
    --- The length of its source, which stands for the time its check takes.
    size: integer
  end
end

--- What a module costs beyond its size: the checker's fixed work on a
--- file, however short.
local fixed_cost <const> = 1500

--- What compiling a module a process has checked already costs beyond
--- that check, as a share of its weight: generating its Lua, dumping
--- its bytecode and judging it.
local compile_share <const> = 2

--- The modules `order` holds, each with the modules it requires among
--- them, however far: which of its own imports each stands on. `order`
--- names no module before what it requires.
local function closures(order: {shards.Item}): {string:{string:boolean}}
  local out: mut {string:{string:boolean}} = {}
  for _, item in ipairs(order) do
    local reached: mut {string:boolean} = {}
    for _, name in ipairs(item.requires) do
      local below = out[name]
      if below ~= nil then
        reached[name] = true
        for deeper in pairs(below) do reached[deeper] = true end
      end
    end
    out[item.path] = reached
  end
  return out
end

--- The least loaded of `candidates`, the lowest index among equals.
local function lightest(busy: {integer}, candidates: {integer}): integer
  local best = candidates[1]
  for _, at in ipairs(candidates) do
    if busy[at] < busy[best] then best = at end
  end
  return best
end

--- How much work to leave a shard beyond an even share, in a hundred,
--- before it stops taking the modules it checks the imports of already:
--- a plan is made for each and the best is kept. A share of 0 places
--- each module on the shard that ends up lightest.
local slacks <const>: {integer} = { 110, 125, 150, 0 }

--- What one placement of the modules to compile came to.
local record Placed
  owner: {string:integer}
  heaviest: integer
  total: integer
end

--- Places each of `heads` and then the rest of `wanted` on one of
--- `count` shards, which each take what `closure` says they must check.
--- With a `slack`, a head goes to the shard it adds the least to among
--- those it leaves no heavier than an even share and `slack` in a hundred
--- more, so a module's imports are checked in few shards; without one,
--- to the shard that ends lightest.
local function place_all(order: {shards.Item}, wanted: {string:boolean},
                         closure: {string:{string:boolean}}, weight: {string:integer},
                         heads: {shards.Item}, count: integer, slack: integer): Placed
  local even = 0
  for _, item in ipairs(order) do
    even = even + weight[item.path]
    if wanted[item.path] then even = even + weight[item.path] // compile_share end
  end
  local limit = even * slack // (count * 100)

  local checked: mut {{string:boolean}} = {}
  local busy: mut {integer} = {}
  for at = 1, count do
    checked[at] = {}
    busy[at] = 0
  end
  local owner: {string:integer} = {}
  local function added(item: shards.Item, at: integer): integer
    local more = weight[item.path] // compile_share
    if not checked[at][item.path] then more = more + weight[item.path] end
    for name in pairs(closure[item.path]) do
      if not checked[at][name] then more = more + weight[name] end
    end
    return more
  end
  local function place(item: shards.Item, at: integer)
    local seen = checked[at]
    for name in pairs(closure[item.path]) do
      if not seen[name] then
        seen[name] = true
        busy[at] = busy[at] + weight[name]
      end
    end
    if not seen[item.path] then
      seen[item.path] = true
      busy[at] = busy[at] + weight[item.path]
    end
    busy[at] = busy[at] + weight[item.path] // compile_share
    owner[item.path] = at
  end

  for _, head in ipairs(heads) do
    local best, best_rank, best_second, best_ends = 0, 0, 0, 0
    for at = 1, count do
      local more = added(head, at)
      local ends = busy[at] + more
      -- Shards that fit rank by what the head adds, the rest and all of
      -- them without a slack by where they end up.
      local fits = slack > 0 and ends <= limit
      local rank = if fits then 0 else 1 end
      local second = fits and more or ends
      if best == 0 or rank < best_rank or
          (rank == best_rank and (second < best_second or
              (second == best_second and ends < best_ends))) then
        best, best_rank, best_second, best_ends = at, rank, second, ends
      end
    end
    place(head, best)
  end

  -- What a head stands on is checked wherever the head went; the
  -- module compiles on the lightest of those, once.
  for _, item in ipairs(order) do
    if wanted[item.path] and owner[item.path] == nil then
      local holders: mut {integer} = {}
      for at = 1, count do
        if checked[at][item.path] then holders[#holders + 1] = at end
      end
      if #holders == 0 then
        for at = 1, count do holders[#holders + 1] = at end
      end
      place(item, lightest(busy, holders))
    end
  end

  local heaviest, total = 0, 0
  for at = 1, count do
    total = total + busy[at]
    if busy[at] > heaviest then heaviest = busy[at] end
  end
  return { owner = owner, heaviest = heaviest, total = total }
end

--- Shares `wanted`, the modules to compile, among at most `count`
--- shards; answers each shard's paths in the order `order` has them,
--- which names no module before what it requires. A module wanted by
--- no other module's closure is placed first, the largest first; a
--- module another wanted one requires goes to a shard that checks it
--- already. Of the placements `slacks` names, the one whose heaviest shard
--- is lightest is kept, the one that checks the least in all among
--- equals. A shard that would be empty is left out, so the answer holds
--- at most `count` lists and each names at least one path.
--- @param order every module of the build, imports first
--- @param wanted the paths to compile, by path
--- @param count how many shards at most
function shards.plan(order: {shards.Item}, wanted: {string:boolean}, count: integer): shards.Plan
  local closure = closures(order)
  local weight: mut {string:integer} = {}
  for _, item in ipairs(order) do weight[item.path] = item.size + fixed_cost end

  -- A module's own weight and what it stands on, to rank the placement.
  local standing: mut {string:integer} = {}
  local required: mut {string:boolean} = {}
  for _, item in ipairs(order) do
    local total = weight[item.path]
    for name in pairs(closure[item.path]) do total = total + weight[name] end
    standing[item.path] = total
    if wanted[item.path] then
      for name in pairs(closure[item.path]) do required[name] = true end
    end
  end

  local heads: mut {shards.Item} = {}
  for _, item in ipairs(order) do
    if wanted[item.path] and not required[item.path] then heads[#heads + 1] = item end
  end
  table.sort(heads, function(a: shards.Item, b: shards.Item): boolean
    if standing[a.path] ~= standing[b.path] then return standing[a.path] > standing[b.path] end
    return a.path < b.path
  end)

  local chosen: Placed? = nil
  for _, slack in ipairs(slacks) do
    local made = place_all(order, wanted, closure, weight, heads, count, slack)
    if chosen == nil or made.heaviest < chosen.heaviest or
        (made.heaviest == chosen.heaviest and made.total < chosen.total) then
      chosen = made
    end
  end
  local kept = assert(chosen)

  local out: mut {{string}} = {}
  for at = 1, count do
    local paths: mut {string} = {}
    for _, item in ipairs(order) do
      if kept.owner[item.path] == at then paths[#paths + 1] = item.path end
    end
    if #paths > 0 then out[#out + 1] = paths end
  end
  return { shards = out, heaviest = kept.heaviest }
end

--- The smallest gain in the heaviest shard that another process is
--- worth, as a share in a hundred: each process added to a build checks
--- the closure of what it compiles again, so the gain falls fast.
local worth_gain <const> = 15

--- [`shards.plan`] for as many shards as pay: one more shard is taken
--- while it cuts the heaviest shard's load by at least `worth_gain` in a
--- hundred, up to `most`. A single list means one process, the build's own,
--- does as well.
--- @param order every module of the build, imports first
--- @param wanted the paths to compile, by path
--- @param most how many shards at most
function shards.best(order: {shards.Item}, wanted: {string:boolean}, most: integer): {{string}}
  local chosen = shards.plan(order, wanted, 1)
  for count = 2, most do
    local more = shards.plan(order, wanted, count)
    if (chosen.heaviest - more.heaviest) * 100 < chosen.heaviest * worth_gain then break end
    chosen = more
  end
  return chosen.shards
end

return shards
