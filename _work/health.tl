--- Board health beyond per-item shape: the stalls `status` renders
--- and `next` must not answer around. Pure over already-read state,
--- the way `_work.flow` is — timestamps arrive from the caller, so
--- nothing here touches git or the filesystem. Three detectors:
---
---   stale claims    a claim is a lock with no expiry, held by
---                   sessions that are ephemeral by construction; a
---                   claimed item whose last board commit is older
---                   than the lease is stalled, not in progress
---   blocker cycles  reciprocal `block` calls racing from two
---                   checkouts edit different files, merge cleanly,
---                   and land a cycle the verb's own check never saw
---   starvation      a `ready` column where every item waits on an
---                   open blocker admits no pull however deep it is;
---                   the actionable fact is the chain's deepest open
---                   blocker, not the count
local flow = require("_work.flow")
local item = require("_work.item")

local type Item = item.Item

--- Seconds since each item's last board commit, by id. Absent entries
--- mean unknown, and unknown never reads as stale.
local type Ages = {string: integer}

--- Seconds a claim holds without a board commit before it reads as
--- stale. Every board mutation is a commit, so an item being actively
--- worked is touched at its pull and again at its handover; between
--- the two there is nothing to commit, which is why the lease is
--- hours against a measured `do` dwell median of 6 minutes (the table
--- in `_work.flow`). The sessions that claim work here are ephemeral
--- cloud or scheduled runs that cannot return an item when they die.
--- Takeover is offered, never automatic: the move that re-claims is
--- still a session's explicit act, on the record.
local LEASE_S < const > = 4 * 60 * 60

--- Whether an item's claim has outlived the lease.
--- @param i Item The item
--- @param ages Ages Seconds since last board commit, by id
--- @return boolean True for a claimed item older than the lease
local function is_stale(i: Item, ages: Ages): boolean
  local age = ages[i.id]
  return (i.claim or "") ~= "" and age ~= nil and age > LEASE_S
end

--- An item's age in whole hours, for rendering.
--- @param i Item The item
--- @param ages Ages Seconds since last board commit, by id
--- @return integer Hours since its last board commit, 0 when unknown
local function stale_hours(i: Item, ages: Ages): integer
  return math.floor((ages[i.id] or 0) / 3600)
end

--- Items whose blocker chain returns to themselves. `flow.is_blocked`
--- reads one hop and `next` silently skips what is blocked, so a
--- cycle starves both items and everything behind them with no
--- diagnostic anywhere — this is that diagnostic.
--- @param items {Item} All items
--- @return {string} Problems, possibly empty
local function blocker_cycle_problems(items: {Item}): {string}
  local index = flow.by_id(items)
  local out: {string} = {}
  for _, i in ipairs(items) do
    if item.is_open(i) and #(i.blocked_by or {}) > 0
    and flow.waits_on(index, i.id, i.id) then
      out[#out + 1] = ("%s: its blocker chain returns to itself — nothing "
        .. "on the cycle can be pulled; break it with `gitboard unblock`")
      :format(i.id)
    end
  end
  return out
end

--- The deepest open blocker an item's chain reaches: the first item
--- along it with no open blocker of its own. Bounded like the parent
--- walk in `_work.flow`, so a cycle in the data returns the last item
--- walked rather than spinning.
--- @param index flow.Index Items by id
--- @param i Item The waiting item
--- @return Item The chain's deepest open item; `i` itself when free
local function chain_root(index: flow.Index, i: Item): Item
  local cur = i
  for _ = 1, 16 do
    local deeper: Item = nil
    for _, b in ipairs(cur.blocked_by or {}) do
      local blocker = index[b]
      if blocker ~= nil and item.is_open(blocker) then
        deeper = blocker
        break
      end
    end
    if deeper == nil then
      return cur
    end
    cur = deeper
  end
  return cur
end

--- The starvation report for `ready`: nil while anything there is
--- pullable, else the chain root every pull is waiting behind and a
--- line saying so. The line names the root's phase and claim because
--- those decide the remedy — finish it, take over its stale claim, or
--- refine it — and a bare "everything is blocked" names none of them.
--- @param b flow.Board The board
--- @param index flow.Index Items by id
--- @param ages Ages Seconds since last board commit, by id
--- @return Item | nil The chain root every ready item waits behind
--- @return string The starvation line
local function starved(b: flow.Board, index: flow.Index,
    ages: Ages): Item | nil, string
  local waiting = b["ready"] or {}
  if #waiting == 0 then
    return nil, ""
  end
  for _, i in ipairs(waiting) do
    if not flow.is_blocked(i, index) then
      return nil, ""
    end
  end
  local root = chain_root(index, waiting[1])
  local where = root.phase
  if where == "" then
    where = "unphased"
  end
  local held = ""
  if (root.claim or "") ~= "" then
    held = (", @%s"):format(root.claim)
    if is_stale(root, ages) then
      held = held .. (" — claim stale %dh"):format(stale_hours(root, ages))
    end
  end
  return root, ("every ready item is blocked; the chain bottoms at %s %s "
    .. "(%s%s) — resolve that before promoting more"):format(
    root.id:sub(1, 8), root.title, where, held)
end

local record health
  type Ages = Ages
  LEASE_S: integer
  is_stale: function(i: Item, ages: Ages): boolean
  stale_hours: function(i: Item, ages: Ages): integer
  blocker_cycle_problems: function(items: {Item}): {string}
  chain_root: function(index: flow.Index, i: Item): Item
  starved: function(b: flow.Board, index: flow.Index,
  ages: Ages): Item | nil, string
end

local M: health = {
  LEASE_S = LEASE_S,
  is_stale = is_stale,
  stale_hours = stale_hours,
  blocker_cycle_problems = blocker_cycle_problems,
  chain_root = chain_root,
  starved = starved,
}

return M
