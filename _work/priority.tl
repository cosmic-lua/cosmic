--- Priority as a recorded RELATION rather than an asserted number:
--- one item outranks another because somebody compared that pair and
--- the comparison was committed. Every item may carry comparisons —
--- there is no privileged tier that alone gets ordered — and the
--- order every queue renders is DERIVED from the edges, never stored
--- beside them.
---
--- The edge lives on the winner as `beats`, one id per entry. A
--- committed comparison is therefore a one-item diff, it survives the
--- append-only history the way every other board fact does, and
--- transitivity does the rest: `A beats B` and `B beats C` settle
--- A against C without anyone being asked.
---
--- Two numbers order the board:
---
---   own   how many items this one dominates through the closure
---   band  the `own` of the nearest self-or-ancestor carrying an edge
---
--- `band` is what lets a comparison at any height place everything
--- beneath it: a leaf nobody compared inherits its parent's standing,
--- so decomposing an item never costs it its position, and comparing
--- two leaves refines the order INSIDE a band without disturbing the
--- bands themselves. An item no edge reaches, at any height, is
--- UNPLACED — it has no position, which is the whole of what the
--- triage queue means.
---
--- Pure functions over a list of items: no store, no network. The
--- module deliberately requires only `_work.item`, so `_work.flow`
--- may build on it without a cycle.
local item = require("_work.item")

local type Item = item.Item

--- Items indexed by id.
local type Index = {string: Item}

--- The most parent hops a placement walk takes before giving up.
--- Matches `_work.flow`'s own trace bound: deeper nesting than this
--- is its own design smell, and a chain this long is cyclic in
--- practice.
local MAX_DEPTH < const > = 16

--- One item's position in the derived order.
local record Position
  --- Whether any edge reaches this item, itself or through an
  --- ancestor. An unplaced item has no priority at all.
  placed: boolean
  --- The dominance count of the nearest placed self-or-ancestor: the
  --- band this item sits in. -1 when unplaced, so band order alone
  --- sorts the unplaced last.
  band: integer
  --- This item's OWN dominance count, which orders peers within one
  --- band.
  own: integer
end

--- Items indexed by id.
--- @param items {Item} All items
--- @return Index The index
local function index_of(items: {Item}): Index
  local out: Index = {}
  for _, i in ipairs(items) do
    out[i.id] = i
  end
  return out
end

--- Walk `beats` from `id`, recording every id reached. The `seen`
--- guard bounds a cycle already in the data rather than spinning on
--- it — which is what lets `cycle_problems` ask this question of a
--- board that may already hold one.
--- @param index Index Items by id
--- @param id string The id to walk from
--- @param seen {string: boolean} Ids reached so far
local function walk(index: Index, id: string, seen: {string: boolean})
  local i = index[id]
  if i == nil then
    return
  end
  for _, b in ipairs(i.beats or {}) do
    if index[b] ~= nil and not seen[b] then
      seen[b] = true
      walk(index, b, seen)
    end
  end
end

--- Every id `id` outranks, directly or transitively. `id` itself
--- appears in the result only when the edges form a cycle through
--- it, which is precisely the cycle test.
--- @param index Index Items by id
--- @param id string The item's id
--- @return {string: boolean} The dominated set, possibly empty
local function dominated(index: Index, id: string): {string: boolean}
  local seen: {string: boolean} = {}
  walk(index, id, seen)
  return seen
end

--- The ids some item names in its `beats`: the in-edge set. An item
--- here participates in the relation even when it beats nothing
--- itself, which is how the bottom of an order is still placed.
--- @param index Index Items by id
--- @return {string: boolean} Ids that something outranks
local function beaten_set(index: Index): {string: boolean}
  local out: {string: boolean} = {}
  for _, i in pairs(index) do
    for _, b in ipairs(i.beats or {}) do
      if index[b] ~= nil then
        out[b] = true
      end
    end
  end
  return out
end

--- Whether an item names at least one edge the board can see. An id
--- with no item behind it is not an edge, the same way a blocker the
--- board does not hold does not block: placement is a statement about
--- recorded comparisons, and a typo is not one.
--- @param index Index Items by id
--- @param i Item The item
--- @return boolean True when some named id exists
local function has_out_edge(index: Index, i: Item): boolean
  for _, b in ipairs(i.beats or {}) do
    if index[b] ~= nil then
      return true
    end
  end
  return false
end

--- How many entries a set holds.
--- @param set {string: boolean} The set
--- @return integer The count
local function count(set: {string: boolean}): integer
  local n = 0
  for _ in pairs(set) do
    n = n + 1
  end
  return n
end

--- Every item's position: its own dominance count, and the band it
--- inherits from the nearest self-or-ancestor an edge reaches.
--- @param items {Item} All items
--- @return {string: Position} Position by item id
local function positions(items: {Item}): {string: Position}
  local index = index_of(items)
  local beaten = beaten_set(index)
  local own: {string: integer} = {}
  for _, i in ipairs(items) do
    own[i.id] = count(dominated(index, i.id))
  end
  local out: {string: Position} = {}
  for _, i in ipairs(items) do
    local band = -1
    local cur = i
    for _ = 1, MAX_DEPTH do
      if has_out_edge(index, cur) or beaten[cur.id] then
        band = own[cur.id] or 0
        break
      end
      local parent = index[cur.parent or ""]
      if parent == nil then
        break
      end
      cur = parent
    end
    out[i.id] = {placed = band >= 0, band = band, own = own[i.id] or 0}
  end
  return out
end

--- One item's sort key, as the two numbers `sorted` compares. An id
--- with no position sorts as unplaced rather than erroring: a queue
--- renders whatever it holds.
--- @param pos {string: Position} Position by item id
--- @param id string The item's id
--- @return integer The band, -1 when unplaced
--- @return integer The own dominance count
local function key_of(pos: {string: Position}, id: string): integer, integer
  local p = pos[id]
  if p == nil then
    return -1, 0
  end
  return p.band, p.own
end

--- Whether an item has a position in the order.
--- @param pos {string: Position} Position by item id
--- @param id string The item's id
--- @return boolean True when some edge reaches it or an ancestor
local function is_placed(pos: {string: Position}, id: string): boolean
  local p = pos[id]
  return p ~= nil and p.placed
end

--- A new copy of `list` in priority order: band first, then own
--- standing within the band, then age. Age is the LAST word rather
--- than the only one — ids are KSUIDs, so it remains an exact and
--- total tie-break for everything no comparison separates.
--- @param list {Item} The items to order
--- @param pos {string: Position} Position by item id
--- @return {Item} A sorted copy
local function sorted(list: {Item}, pos: {string: Position}): {Item}
  local out: {Item} = {}
  for _, i in ipairs(list) do
    out[#out + 1] = i
  end
  table.sort(out, function(x: Item, y: Item): boolean
      local xband, xown = key_of(pos, x.id)
      local yband, yown = key_of(pos, y.id)
      if xband ~= yband then
        return xband > yband
      end
      if xown ~= yown then
        return xown > yown
      end
      return x.id < y.id
    end)
  return out
end

--- The cycles the edges hold, one line each. A cycle is never
--- averaged away: it means the comparison question was ambiguous, so
--- the pair is restated and re-asked. Reported, never repaired.
--- @param items {Item} All items
--- @return {string} Problems, possibly empty
local function cycle_problems(items: {Item}): {string}
  local index = index_of(items)
  local out: {string} = {}
  for _, i in ipairs(items) do
    if dominated(index, i.id)[i.id] then
      out[#out + 1] = ("%s: priority edges form a cycle through it — the "
        .. "comparison was ambiguous; restate it and re-compare the pair")
      :format(i.id)
    end
  end
  return out
end

--- The refusal recording `winner > loser` earns, or nil when the
--- edge may be written. A comparison that contradicts one already
--- committed is refused rather than silently reversing it: the
--- earlier judgment is data, and overturning it is `uncompare` then
--- `compare`, two commits that both show in the log.
--- @param index Index Items by id
--- @param winner string The id ranked above
--- @param loser string The id ranked below
--- @return string | nil The refusal
local function edge_refusal(index: Index, winner: string,
    loser: string): string | nil
  if winner == loser then
    return "an item cannot outrank itself"
  end
  if index[winner] == nil then
    return ("no item %s"):format(winner)
  end
  if index[loser] == nil then
    return ("no item %s"):format(loser)
  end
  for _, b in ipairs(index[winner].beats or {}) do
    if b == loser then
      return ("%s already outranks %s"):format(winner:sub(1, 8),
        loser:sub(1, 8))
    end
  end
  if dominated(index, loser)[winner] then
    return ("%s already outranks %s — recording the reverse would make the "
      .. "order cyclic; drop the standing edge first"):format(
      loser:sub(1, 8), winner:sub(1, 8))
  end
  return nil
end

local record priority
  type Item = Item
  type Index = Index
  type Position = Position
  index_of: function(items: {Item}): Index
  dominated: function(index: Index, id: string): {string: boolean}
  beaten_set: function(index: Index): {string: boolean}
  has_out_edge: function(index: Index, i: Item): boolean
  positions: function(items: {Item}): {string: Position}
  key_of: function(pos: {string: Position}, id: string): integer, integer
  is_placed: function(pos: {string: Position}, id: string): boolean
  sorted: function(list: {Item}, pos: {string: Position}): {Item}
  cycle_problems: function(items: {Item}): {string}
  edge_refusal: function(index: Index, winner: string,
  loser: string): string | nil
end

local M: priority = {
  index_of = index_of,
  dominated = dominated,
  beaten_set = beaten_set,
  has_out_edge = has_out_edge,
  positions = positions,
  key_of = key_of,
  is_placed = is_placed,
  sorted = sorted,
  cycle_problems = cycle_problems,
  edge_refusal = edge_refusal,
}

return M
