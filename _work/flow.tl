--- The flow rules over the item graph: pure functions over a list of
--- items, no network and no filesystem. There are no kinds — an
--- item's ROLE derives from its position in the graph, and this
--- module is where that derivation lives:
---
---   container an item with open children (being decomposed)
---   root      a parentless item, organizing or awaiting a decision
---   work      a parented leaf — the only role that holds a phase
---
--- There is no goal tier: every item is the same record, and what
--- makes one outrank another is a committed comparison, derived into
--- an order by `_work.priority`. A queue is therefore priority order
--- with age as the last word, not age alone.
---
--- The board is open PHASED items; roots and containers are never on
--- it, so the label board's carve-outs (the epic exemption, the
--- finding exception, the mandated flag) have nothing to except. What
--- remains of `admits_over_limit` is two lines. The ready bar
--- (`_work.spec.ready_gaps`) is applied to the spec sidecar.
--- WIP limits carry the label board's empirically tuned values;
--- retuning them is a reviewed change here too.
---
--- Their empirical basis, measured over the board branch's full
--- history to 2026-08-20 (70.4 h, 382 commits over `items/`, 279
--- transitions, 99 items, 62 ended), by the stint walk `review.md`
--- describes:
---
---   phase  stints  dwell median  peak  limit  at-or-over
---   plan       62       275 min    21     12   66.3 h (94%)
---   ready      43       235 min    12     12    1.6 h (2%)
---   do         38         6 min     3      5    0
---   check      29       168 min     6     10    0
---   land       33        13 min     4      3    8.0 h (11%)
---
--- `do` and `check` never came near their numbers, so those two are
--- unjudged rather than confirmed; `land`'s peak is above its limit
--- only because an accept is admitted over it, which is not a signal.
--- The tripwires, each a reason to measure again rather than a rule:
---
---   plan   binds almost continuously and holds 992 of the 1155
---          phased item-hours. Pickup latency out of `ready` runs
---          173 min against a 6 min `do`, so most of that depth is
---          inventory aging, not work in flight. While it binds,
---          intake is closed — `action.next_action` decomposes a root
---          only with room in `plan` — so the highest-placed roots go
---          undecomposed for as long as a stalled chain holds the
---          depth, whatever they outrank. That starvation is the cost
---          of this number, not a separate fault: if a review confirms
---          it a second time, this queue is cut, not kept.
---   ready  never binds while holding the same aging; cut with plan
---          rather than alone, since refinement fills it.
---   do     revisit if peak reaches 5 with a mix of claims, which
---          would mean concurrent sessions rather than the one worker
---          measured here. Five slots all held by OTHER sessions is
---          not a limit signal — it is the stalled-claim state
---          `action.next_action` reports.
---   check  revisit if peak reaches 10 with a mix of claims. Reaching
---          10 all from ONE session is not a limit signal — it is the
---          handover stall `action.next_action` reports.
---
--- What a role should DO with all this is `_work.action`: the rules and
--- the policy that consults them are separate modules, so growing one
--- never crowds the other against the file-length cap.
local it = require("_work.item")
local prio = require("_work.priority")
local spec = require("_work.spec")

local type Item = it.Item

--- Open phased items grouped by phase name.
local type Board = {string: {Item}}

--- Items indexed by id.
local type Index = {string: Item}

local LIMITS: {string: integer} = {
  plan = 12,
  ready = 12,
  ["do"] = 5,
  check = 10,
  land = 3,
}

--- The triage queue is not a phase and holds no WIP slot, but an
--- unbounded one starves: captured evidence is the only channel by
--- which an implementer reports friction, and a queue nobody drains
--- makes that channel write-only. This is the depth past which draining it
--- outranks refining. A first value, tuned by the flow review the
--- same way `LIMITS` is.
local TRIAGE_LIMIT < const > = 8

--- The most parent hops a trace walks before calling the chain
--- cyclic; deeper nesting than this is its own design smell.
local MAX_DEPTH < const > = 16

local PHASE_INDEX: {string: integer} = {}
for idx, p in ipairs(it.PHASES) do
  PHASE_INDEX[p] = idx
end

--- Whether moving between two phases is a return: leftward motion.
--- Returns are never refused; they are the system correcting itself.
--- @param from string Current phase name
--- @param to string Target phase name
--- @return boolean True when the move is leftward between known phases
local function is_return(from: string, to: string): boolean
  local a = PHASE_INDEX[from]
  local b = PHASE_INDEX[to]
  return a ~= nil and b ~= nil and b < a
end

--- Whether a full phase admits an arrival anyway. With only workable
--- leaves on the board, two admissions remain: a return, and a move
--- into land — an accept is a decision already made. Everything else
--- queues.
--- @param from string Current phase name, or nil for an entry
--- @param to string Target phase name
--- @return boolean True when the target's WIP limit does not bind
local function admits_over_limit(from: string, to: string): boolean
  return to == "land" or is_return(from, to)
end

--- Whether a mutation adds an item to `to`: entries (nil `from`) and
--- cross-phase moves arrive; a write that leaves the item where it
--- stands (`from == to`) does not.
--- @param from string Phase the mutation left; equal to `it.phase` for
---   a write that moves nothing, nil for an entry
--- @param to string Target phase
--- @return boolean True when the mutation adds an item to `to`
local function is_arrival(from: string, to: string): boolean
  return to ~= "" and from ~= to
end

--- Items indexed by id.
--- @param items {Item} All items
--- @return Index The index
local function by_id(items: {Item}): Index
  local out: Index = {}
  for _, i in ipairs(items) do
    out[i.id] = i
  end
  return out
end

--- Whether an item has an open child.
--- @param items {Item} All items
--- @param id string The candidate parent's id
--- @return boolean True when some open item names it as parent
local function has_open_children(items: {Item}, id: string): boolean
  for _, i in ipairs(items) do
    if i.parent == id and it.is_open(i) then
      return true
    end
  end
  return false
end

--- The role an item's graph position gives it. A root with children
--- and a parented one with children are the same thing — something
--- being decomposed — so nothing distinguishes them here.
--- @param i Item The item
--- @param items {Item} All items
--- @return string "container" | "root" | "work"
local function role(i: Item, items: {Item}): string
  if has_open_children(items, i.id) then
    return "container"
  end
  if it.is_root(i) then
    return "root"
  end
  return "work"
end

--- The board: open phased items grouped by phase.
--- @param items {Item} All items
--- @return Board The board
local function board(items: {Item}): Board
  local out: Board = {}
  for _, i in ipairs(items) do
    if it.is_open(i) and (i.phase or "") ~= "" then
      local phase = out[i.phase] or {}
      phase[#phase + 1] = i
      out[i.phase] = phase
    end
  end
  return out
end

--- Items of one phase in queue order: priority first, age last.
--- Positions arrive from the caller rather than being derived here,
--- so rendering five phases derives the order once. Returns a new
--- sorted copy.
--- @param b Board The board
--- @param phase string Phase name
--- @param pos {string: prio.Position} Position by item id
--- @return {Item} Sorted items, possibly empty
local function queued(b: Board, phase: string,
    pos: {string: prio.Position}): {Item}
  return prio.sorted(b[phase] or {}, pos)
end

--- WIP-limit violations, one line each ("do 6/5 over limit").
---
--- A phase reports at TWO thresholds, because the gate has two. An
--- ordinary arrival is refused from `count == limit` upward
--- (`gitgate.wip_refusal` admits below the limit, not at it), so a
--- phase sitting exactly at its number is already turning work away —
--- and reporting only `count > limit` printed `WIP ok` over a board
--- that could not accept another item. `land` is excluded from the
--- at-limit line alone: an accept is admitted over the limit however
--- full it is, so `land` at its number refuses nothing.
--- @param b Board The board
--- @return {string} Violations, left-to-right phase order
local function wip_violations(b: Board): {string}
  local out: {string} = {}
  for _, phase in ipairs(it.PHASES) do
    local n = #(b[phase] or {})
    if n > LIMITS[phase] then
      out[#out + 1] = ("%s %d/%d over limit"):format(phase, n, LIMITS[phase])
    elseif n == LIMITS[phase] and not admits_over_limit("", phase) then
      out[#out + 1] = ("%s %d/%d at limit — arrivals refused"):format(
        phase, n, LIMITS[phase])
    end
  end
  return out
end

--- Whether an item waits on an open blocker. A blocker id with no
--- item behind it does not block — the board reasons about state it
--- holds.
--- @param i Item The item
--- @param index Index Items by id
--- @return boolean True when some named blocker is open
local function is_blocked(i: Item, index: Index): boolean
  for _, b in ipairs(i.blocked_by or {}) do
    local blocker = index[b]
    if blocker ~= nil and it.is_open(blocker) then
      return true
    end
  end
  return false
end

--- Whether `from` waits on `target`, directly or through a chain of
--- blockers. Bounded by the items already walked, so a cycle already
--- in the data cannot spin here — which is what lets the `block` verb
--- ask this question of data that may already hold one.
--- @param index Index Items by id
--- @param from string The waiting item's id
--- @param target string The id it might be waiting on
--- @param seen {string: boolean} Ids already walked; nil to start
--- @return boolean True when a blocker chain leads from `from` to `target`
local function waits_on(index: Index, from: string, target: string,
    seen?: {string: boolean}): boolean
  local walked = seen or {}
  if walked[from] then
    return false
  end
  walked[from] = true
  local i = index[from]
  if i == nil then
    return false
  end
  for _, b in ipairs(i.blocked_by or {}) do
    if b == target or waits_on(index, b, target, walked) then
      return true
    end
  end
  return false
end

--- The root an item's parent chain reaches, or nil for a broken or
--- cyclic chain.
--- @param i Item The item
--- @param index Index Items by id
--- @return Item | nil The root
local function root_of(i: Item, index: Index): Item | nil
  local cur = i
  for _ = 1, MAX_DEPTH do
    if it.is_root(cur) then
      return cur
    end
    cur = index[cur.parent]
    if cur == nil then
      return nil
    end
  end
  return nil
end

--- ONE item's graph problems: a parent that does not exist, a chain
--- that never reaches a root, a phase held by something that is not a
--- workable leaf, phased work with no position in the priority
--- order, and the reverse — an open leaf left with no phase, which is
--- off the board without being finished.
---
--- Placement is what the goal trace used to be. The old rule asked
--- whether a chain reached a RANKED root, which answered "is this
--- worth doing" by genealogy; the question is now ordinal — where
--- does this sit against everything else — and an item nothing has
--- been compared against, at any height, has no answer to it.
---
--- Scoped to the one item on purpose: the ready bar asks it of the
--- item being promoted, so an unrelated item's broken chain can never
--- refuse a promotion that has nothing to do with it. `status` asks
--- it of everything, which is where board-wide health belongs.
--- @param i Item The item
--- @param items {Item} All items
--- @param index Index Items by id
--- @param pos {string: prio.Position} Positions; derived here when omitted
--- @return {string} Problems, possibly empty
local function item_problems(i: Item, items: {Item}, index: Index,
    pos?: {string: prio.Position}): {string}
  local out: {string} = {}
  if not it.is_root(i) and index[i.parent] == nil then
    out[#out + 1] = ("%s: parent %s does not exist"):format(i.id, i.parent)
    return out
  end
  if not it.is_open(i) then
    return out
  end
  if (i.phase or "") == "" then
    if not it.is_root(i) and not has_open_children(items, i.id) then
      out[#out + 1] = ("%s: a workable leaf with no phase — it is off the "
        .. "board without being finished; move it into plan or end it")
      :format(i.id)
    end
    return out
  end
  if has_open_children(items, i.id) then
    out[#out + 1] = ("%s: phased but has open children — finish the "
      .. "decomposition or clear its phase"):format(i.id)
  end
  local root = root_of(i, index)
  if root == nil then
    out[#out + 1] = ("%s: parent chain is broken or cyclic"):format(i.id)
  end
  local at = pos or prio.positions(items)
  if not prio.is_placed(at, i.id) then
    out[#out + 1] = ("%s: has no position in the priority order — compare "
      .. "it against something with `gitboard compare <id> <id>`, or attach "
      .. "it under an item that has one"):format(i.id)
  end
  return out
end

--- Every item's graph problems, plus any cycle the priority edges
--- hold, for board-wide health.
--- @param items {Item} All items
--- @return {string} Problems, possibly empty
local function graph_problems(items: {Item}): {string}
  local index = by_id(items)
  local at = prio.positions(items)
  local out: {string} = {}
  for _, i in ipairs(items) do
    for _, p in ipairs(item_problems(i, items, index, at)) do
      out[#out + 1] = p
    end
  end
  for _, p in ipairs(prio.cycle_problems(items)) do
    out[#out + 1] = p
  end
  return out
end

--- The open roots that have a POSITION, in priority order, each with
--- whether live work already drives it (an open item whose parent
--- chain reaches it). These are what the board used to call goals;
--- nothing marks them as such any more — a root is one of these by
--- having been compared against something, which is the only claim
--- to importance the board recognises.
--- @param items {Item} All items
--- @return {Item} Open placed roots, priority order
--- @return {string: boolean} root id -> has live work
local function roots(items: {Item}): {Item}, {string: boolean}
  local index = by_id(items)
  local at = prio.positions(items)
  local out: {Item} = {}
  local live: {string: boolean} = {}
  for _, i in ipairs(items) do
    if it.is_open(i) then
      if it.is_root(i) then
        if prio.is_placed(at, i.id) then
          out[#out + 1] = i
        end
      else
        local root = root_of(i, index)
        if root ~= nil then
          live[root.id] = true
        end
      end
    end
  end
  return prio.sorted(out, at), live
end

--- The triage queue: open, childless, parentless items that no
--- comparison has placed. Captured evidence, nothing decomposing it,
--- nothing having adopted it, and no claim yet about how much it
--- matters — which is exactly the state triage exists to resolve, by
--- attaching it under something placed, comparing it, or ending it.
---
--- Placement is what separates this queue from intake: a root
--- somebody HAS compared is an outcome the planner decomposes
--- (`roots`), even with no children yet.
--- @param items {Item} All items
--- @return {Item} Unplaced roots, age order
local function untriaged(items: {Item}): {Item}
  local at = prio.positions(items)
  local out: {Item} = {}
  for _, i in ipairs(items) do
    if it.is_open(i) and it.is_root(i)
    and not has_open_children(items, i.id)
    and not prio.is_placed(at, i.id) then
      out[#out + 1] = i
    end
  end
  return prio.sorted(out, at)
end

--- The triage queue's own limit violation, in the one line shape
--- `wip_violations` uses. Triage holds no phase, so `wip_violations`
--- — which walks the phases — never sees it; the bound still binds.
--- @param items {Item} All items
--- @return string | nil The violation line, nil at or under the bound
local function triage_violation(items: {Item}): string | nil
  local n = #untriaged(items)
  if n > TRIAGE_LIMIT then
    return ("triage %d/%d over limit"):format(n, TRIAGE_LIMIT)
  end
  return nil
end

local record flow
  type Item = Item
  type Board = Board
  type Index = Index
  LIMITS: {string: integer}
  TRIAGE_LIMIT: integer
  is_return: function(from: string, to: string): boolean
  admits_over_limit: function(from: string, to: string): boolean
  is_arrival: function(from: string, to: string): boolean
  by_id: function(items: {Item}): Index
  has_open_children: function(items: {Item}, id: string): boolean
  role: function(i: Item, items: {Item}): string
  board: function(items: {Item}): Board
  queued: function(b: Board, phase: string,
  pos: {string: prio.Position}): {Item}
  wip_violations: function(b: Board): {string}
  is_blocked: function(i: Item, index: Index): boolean
  waits_on: function(index: Index, from: string, target: string,
  seen?: {string: boolean}): boolean
  root_of: function(i: Item, index: Index): Item | nil
  item_problems: function(i: Item, items: {Item}, index: Index,
  pos?: {string: prio.Position}): {string}
  graph_problems: function(items: {Item}): {string}
  roots: function(items: {Item}): {Item}, {string: boolean}
  untriaged: function(items: {Item}): {Item}
  triage_violation: function(items: {Item}): string | nil
  ready_gaps: function(body: string): {string}
end

local M: flow = {
  LIMITS = LIMITS,
  TRIAGE_LIMIT = TRIAGE_LIMIT,
  is_return = is_return,
  admits_over_limit = admits_over_limit,
  is_arrival = is_arrival,
  by_id = by_id,
  has_open_children = has_open_children,
  role = role,
  board = board,
  queued = queued,
  wip_violations = wip_violations,
  is_blocked = is_blocked,
  waits_on = waits_on,
  root_of = root_of,
  item_problems = item_problems,
  graph_problems = graph_problems,
  roots = roots,
  untriaged = untriaged,
  triage_violation = triage_violation,
  ready_gaps = spec.ready_gaps,
}

return M
