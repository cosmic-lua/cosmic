--- The intake half of the next-action ordering: everything upstream
--- of a claim. `_work.action` decides the phased half — land, review,
--- finish, pull — and consults this only when none of those has work,
--- so nothing here ever outranks moving something that is already in
--- flight.
---
--- The rungs, in order: drain a triage queue past its bound, refine
--- what is already committed, commit to the next thing, sweep what
--- has rotted, triage the remainder, and decompose an undriven root.
---
--- TWO rungs feed the pipeline where there used to be one, because
--- placing an item and committing to it are different decisions with
--- different costs. Triage answers "is this real, and under which
--- outcome" and writes into an unbounded `backlog`; promotion answers
--- "am I refining this to the ready bar now" and writes into a small
--- `plan`. Fusing them made the cheap answer carry the expensive
--- one's weight: a triage drain deposited a batch of commitments
--- nobody had sized, `plan` grew without bound because no rung ever
--- pushed back on it, and the queue that was supposed to be a
--- commitment register became a holding pen.
---
--- Refinement outranks promotion for the reason finishing outranks
--- starting: an item already committed to is closer to `ready` than
--- one nobody has picked. Sweeping sits below both, so a keep-or-kill
--- pass is what a session does when it cannot do anything more
--- valuable — never instead of real work.
local decision = require("_work.decision")
local flow = require("_work.flow")
local health = require("_work.health")
local item = require("_work.item")
local prio = require("_work.priority")

local type Item = item.Item
local type Action = decision.Action

--- The highest-placed item of a phase that nothing open blocks, and
--- how many it stepped over. `pull` skips a blocked ready item, so
--- advancing one promotes work the other end of the ordering will not
--- take: it consumes a slot and waits there for a blocker that the
--- promotion cannot advance. Both feeding rungs skip the same way.
--- @param b flow.Board The board
--- @param phase string Phase to draw from
--- @param index flow.Index Items by id
--- @param pos {string: prio.Position} Position by item id
--- @return Item | nil The first unblocked item
--- @return integer How many blocked items were skipped
local function first_unblocked(b: flow.Board, phase: string,
    index: flow.Index, pos: {string: prio.Position}): Item | nil, integer
  local found: Item = nil
  local waiting = 0
  for _, i in ipairs(flow.queued(b, phase, pos)) do
    if flow.is_blocked(i, index) then
      waiting = waiting + 1
    elseif found == nil then
      found = i
    end
  end
  return found, waiting
end

--- The LOWEST-placed rotten backlog item, and how many have rotted.
--- Lowest rather than oldest: age says the decision has gone unmade,
--- placement says how little it would cost to make it "no". Sweeping
--- from the bottom asks about the items least likely to be worth
--- keeping, so the pass converges on closing rather than on
--- re-litigating work that merely has not come up yet.
--- @param b flow.Board The board
--- @param pos {string: prio.Position} Position by item id
--- @param ages health.Ages Seconds since last board commit, by id
--- @return Item | nil The item to decide about
--- @return integer How many backlog items have rotted
local function last_rotten(b: flow.Board, pos: {string: prio.Position},
    ages: health.Ages): Item | nil, integer
  local found: Item = nil
  local rotten = 0
  for _, i in ipairs(flow.queued(b, "backlog", pos)) do
    if health.is_rotten(i, ages) then
      rotten = rotten + 1
      found = i
    end
  end
  return found, rotten
end

--- What an advancing rung says about the item it chose beyond its own
--- standing: how many blocked items it stepped over, and how many
--- open items it would unblock. Both tiebreaks order the queue, and
--- an ordering a session cannot see reads as the wrong item being
--- handed out.
--- @param pos {string: prio.Position} Position by item id
--- @param i Item The chosen item
--- @param waiting integer Blocked items skipped
--- @return string The trailer, empty when there is nothing to say
local function trailer(pos: {string: prio.Position}, i: Item,
    waiting: integer): string
  local out = ""
  if waiting > 0 then
    out = (", %d blocked and skipped"):format(waiting)
  end
  local _band, _own, frees = prio.order_of(pos, i.id)
  if frees > 0 then
    out = out .. (" — it unblocks %d open item(s)"):format(frees)
  end
  return out
end

--- The intake decision, or nil when intake has nothing to offer.
--- @param items {Item} All items
--- @param b flow.Board The board
--- @param index flow.Index Items by id
--- @param pos {string: prio.Position} Position by item id
--- @param ages health.Ages Seconds since last board commit, by id
--- @return Action | nil The decision
local function intake_action(items: {Item}, b: flow.Board, index: flow.Index,
    pos: {string: prio.Position}, ages: health.Ages): Action | nil
  local triage = flow.untriaged(items)
  if #triage > flow.TRIAGE_LIMIT then
    return {
      kind = "triage",
      item = triage[1],
      reason = ("%d item(s) awaiting triage, over the bound of %d — "
        .. "draining outranks refining"):format(#triage, flow.TRIAGE_LIMIT),
    }
  end
  local refining, waiting = first_unblocked(b, "plan", index, pos)
  if refining ~= nil and #(b["ready"] or {}) < flow.LIMITS["ready"] then
    return {
      kind = "refine",
      item = refining,
      reason = ("ready holds %d/%d — refine a committed item toward the "
        .. "bar%s"):format(#(b["ready"] or {}), flow.LIMITS["ready"],
        trailer(pos, refining, waiting)),
    }
  end
  local promoting, blocked = first_unblocked(b, "backlog", index, pos)
  if promoting ~= nil and #(b["plan"] or {}) < flow.LIMITS["plan"] then
    return {
      kind = "promote",
      item = promoting,
      reason = ("plan holds %d/%d — commit to the highest-placed backlog "
        .. "item%s"):format(#(b["plan"] or {}), flow.LIMITS["plan"],
        trailer(pos, promoting, blocked)),
    }
  end
  -- Below both feeding rungs: reaching here means nothing to land,
  -- review, finish or pull, triage under its bound, and `plan` and
  -- `ready` both full. A keep-or-kill pass is then the most valuable
  -- thing left, and it is the only rung that proposes ending work
  -- nobody has argued against — which is why it asks rather than
  -- acts.
  local rotten, count = last_rotten(b, pos, ages)
  if rotten ~= nil then
    return {
      kind = "sweep",
      item = rotten,
      reason = ("%d backlog item(s) untouched for over %d days — this is "
        .. "the lowest-placed: promote it, or end it `not-planned`")
      :format(count, health.ROT_S // (24 * 60 * 60)),
    }
  end
  if #triage > 0 then
    return {
      kind = "triage",
      item = triage[1],
      reason = ("%d item(s) await triage — attach it under something "
        .. "placed, compare it, or close it"):format(#triage),
    }
  end
  -- Decomposition is ungated now that it writes into an unbounded
  -- `backlog`. It used to wait on room in `plan`, which meant a
  -- stalled refinement queue closed intake and starved the
  -- highest-placed roots however far they outranked what was holding
  -- the depth — the cost the old limit charged without ever being
  -- asked to.
  local ordered, live = flow.roots(items)
  for _, g in ipairs(ordered) do
    if not live[g.id] then
      return {
        kind = "intake",
        item = g,
        reason = ("%s has no live work — decompose it"):format(
          g.id:sub(1, 8)),
      }
    end
  end
  -- Only worth saying when there ARE placed roots: with none, "every
  -- open root has live work" is vacuously true and tells a session
  -- nothing about why it has been handed no work.
  if #ordered > 0 then
    return {kind = "intake", reason = "every open root has live work — "
      .. "work backwards from the highest-placed one with slack"}
  end
  return nil
end

local record intake
  first_unblocked: function(b: flow.Board, phase: string,
  index: flow.Index, pos: {string: prio.Position}): Item | nil, integer
  last_rotten: function(b: flow.Board, pos: {string: prio.Position},
  ages: health.Ages): Item | nil, integer
  intake_action: function(items: {Item}, b: flow.Board, index: flow.Index,
  pos: {string: prio.Position}, ages: health.Ages): Action | nil
end

local M: intake = {
  first_unblocked = first_unblocked,
  last_rotten = last_rotten,
  intake_action = intake_action,
}

return M
