--- The flow rules over the item graph: pure functions from a list of
--- items to decisions, no network and no filesystem. There are no
--- kinds — an item's ROLE derives from its position in the graph, and
--- this module is where that derivation lives:
---
---   goal      a ranked root
---   finding   an unranked root (captured evidence, awaiting triage)
---   container a parented item with open children (being decomposed)
---   work      a parented leaf — the only role that holds a phase
---
--- The board is open PHASED items; roots and containers are never on
--- it, so the label board's carve-outs (the epic exemption, the
--- finding exception, the mandated flag) have nothing to except. What
--- remains of `admits_over_limit` is two lines. The ready bar
--- (`_work.model.ready_gaps`) is reused as-is over the spec sidecar.
--- WIP limits carry the label board's empirically tuned values;
--- retuning them is a reviewed change here too. Ids are KSUIDs, so
--- sorting by id IS sorting by age and "oldest first" needs no other
--- field.
local it = require("_work.item")
local model = require("_work.model")

local type Item = it.Item

--- Open phased items grouped by phase name.
local type Board = {string: {Item}}

--- Items indexed by id.
local type Index = {string: Item}

--- The tool's one answer to "what should I do now".
local record NextAction
  --- "review" | "refine" | "triage" | "intake" | "finish" | "pull" | "none"
  kind: string
  --- The item the action targets; nil for intake-with-no-goal and none.
  item: Item
  --- The rule that chose this action, stated for the human/agent.
  reason: string
end

local LIMITS: {string: integer} = {
  plan = 12,
  ready = 12,
  ["do"] = 5,
  check = 10,
  land = 3,
}

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

--- The role an item's graph position gives it.
--- @param i Item The item
--- @param items {Item} All items
--- @return string "goal" | "finding" | "container" | "work"
local function role(i: Item, items: {Item}): string
  if it.is_root(i) then
    if (i.rank or 0) > 0 then
      return "goal"
    end
    return "finding"
  end
  if has_open_children(items, i.id) then
    return "container"
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

--- Items of one phase, oldest first — id order IS age order, because
--- ids are KSUIDs. Returns a new sorted copy.
--- @param b Board The board
--- @param phase string Phase name
--- @return {Item} Sorted items, possibly empty
local function oldest_first(b: Board, phase: string): {Item}
  local list: {Item} = {}
  for _, i in ipairs(b[phase] or {}) do
    list[#list + 1] = i
  end
  table.sort(list, function(x: Item, y: Item): boolean
      return x.id < y.id
    end)
  return list
end

--- WIP-limit violations, one line each ("do 6/5 over limit").
--- @param b Board The board
--- @return {string} Violations, left-to-right phase order
local function wip_violations(b: Board): {string}
  local out: {string} = {}
  for _, phase in ipairs(it.PHASES) do
    local n = #(b[phase] or {})
    if n > LIMITS[phase] then
      out[#out + 1] = ("%s %d/%d over limit"):format(phase, n, LIMITS[phase])
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

--- The root an item's parent chain reaches, or nil for a broken or
--- cyclic chain.
--- @param i Item The item
--- @param index Index Items by id
--- @return Item | nil The root
local function root_of(i: Item, index: Index): Item
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
--- workable leaf, work that traces to no ranked goal, and the reverse
--- — an open leaf left with no phase, which is off the board without
--- being finished. This is the goal trace as a checked property
--- instead of a prose convention.
---
--- Scoped to the one item on purpose: the ready bar asks it of the
--- item being promoted, so an unrelated item's broken chain can never
--- refuse a promotion that has nothing to do with it. `status` asks
--- it of everything, which is where board-wide health belongs.
--- @param i Item The item
--- @param items {Item} All items
--- @param index Index Items by id
--- @return {string} Problems, possibly empty
local function item_problems(i: Item, items: {Item}, index: Index): {string}
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
  elseif (root.rank or 0) < 1 then
    out[#out + 1] = ("%s: traces to %s, which is unranked — adopt the "
      .. "finding or rank the root"):format(i.id, root.id)
  end
  return out
end

--- Every item's graph problems, for board-wide health.
--- @param items {Item} All items
--- @return {string} Problems, possibly empty
local function trace_problems(items: {Item}): {string}
  local index = by_id(items)
  local out: {string} = {}
  for _, i in ipairs(items) do
    for _, p in ipairs(item_problems(i, items, index)) do
      out[#out + 1] = p
    end
  end
  return out
end

--- The oldest ready item an implementer may pull: no open blocker.
--- @param b Board The board
--- @param index Index Items by id
--- @return Item | nil The pullable item
local function first_pullable(b: Board, index: Index): Item
  for _, i in ipairs(oldest_first(b, "ready")) do
    if not is_blocked(i, index) then
      return i
    end
  end
  return nil
end

--- The open goals ranked, each with whether live work already drives
--- it (an open item whose parent chain reaches it).
--- @param items {Item} All items
--- @return {Item} Open goals, rank order
--- @return {string: boolean} goal id -> has live work
local function goals(items: {Item}): {Item}, {string: boolean}
  local index = by_id(items)
  local out: {Item} = {}
  local live: {string: boolean} = {}
  for _, i in ipairs(items) do
    if it.is_open(i) then
      if it.is_root(i) and (i.rank or 0) > 0 then
        out[#out + 1] = i
      elseif not it.is_root(i) then
        local root = root_of(i, index)
        if root ~= nil then
          live[root.id] = true
        end
      end
    end
  end
  table.sort(out, function(x: Item, y: Item): boolean
      if x.rank ~= y.rank then
        return x.rank < y.rank
      end
      return x.id < y.id
    end)
  return out, live
end

--- Open findings (unranked roots), oldest first: the triage queue.
--- @param items {Item} All items
--- @return {Item} Findings, possibly empty
local function findings(items: {Item}): {Item}
  local out: {Item} = {}
  for _, i in ipairs(items) do
    if it.is_open(i) and it.is_root(i) and (i.rank or 0) == 0 then
      out[#out + 1] = i
    end
  end
  table.sort(out, function(x: Item, y: Item): boolean
      return x.id < y.id
    end)
  return out
end

--- The implementer's next action, right to left: land, then do, then
--- pull ready. Whatever is closest to completion moves first.
--- @param items {Item} All items
--- @return NextAction The decision
local function next_for_implementer(items: {Item}): NextAction
  local b = board(items)
  local index = by_id(items)
  local landing = oldest_first(b, "land")
  if #landing > 0 then
    return {
      kind = "finish",
      item = landing[1],
      reason = ("land holds %d/%d — %s is accepted, awaiting merge"):format(
        #landing, LIMITS["land"], landing[1].id:sub(1, 8)),
    }
  end
  local doing = oldest_first(b, "do")
  if #doing > 0 then
    return {
      kind = "finish",
      item = doing[1],
      reason = ("do holds %d/%d — finish before pulling"):format(
        #doing, LIMITS["do"]),
    }
  end
  local pullable = first_pullable(b, index)
  if pullable then
    return {
      kind = "pull",
      item = pullable,
      reason = "oldest ready item with no open blocker",
    }
  end
  local waiting = #(b["check"] or {})
  if waiting > 0 then
    return {
      kind = "none",
      reason = ("%d item(s) await a planner verdict — that verdict is the "
        .. "bottleneck"):format(waiting),
    }
  end
  return {kind = "none", reason = "no ready work — a planner session must "
    .. "refine or intake"}
end

--- The planner's next action: verdicts first, then refine plan toward
--- ready while ready has slack, then triage findings, then intake the
--- top-ranked goal that no live work drives, else nothing.
--- @param items {Item} All items
--- @return NextAction The decision
local function next_for_planner(items: {Item}): NextAction
  local b = board(items)
  local checking = oldest_first(b, "check")
  if #checking > 0 then
    return {
      kind = "review",
      item = checking[1],
      reason = "check is the rightmost planner phase — verdicts first",
    }
  end
  local planning = oldest_first(b, "plan")
  if #planning > 0 and #(b["ready"] or {}) < LIMITS["ready"] then
    return {
      kind = "refine",
      item = planning[1],
      reason = ("ready holds %d/%d — refine a plan item toward the bar")
      :format(#(b["ready"] or {}), LIMITS["ready"]),
    }
  end
  local triage = findings(items)
  if #triage > 0 then
    return {
      kind = "triage",
      item = triage[1],
      reason = ("%d finding(s) await triage — attach it under a goal or "
        .. "close it"):format(#triage),
    }
  end
  if #(b["plan"] or {}) < LIMITS["plan"] then
    local ranked, live = goals(items)
    for _, g in ipairs(ranked) do
      if not live[g.id] then
        return {
          kind = "intake",
          item = g,
          reason = ("goal %s (rank %d) has no live work — decompose it")
          :format(g.id:sub(1, 8), g.rank),
        }
      end
    end
    return {kind = "intake", reason = "every open goal has live work — work "
      .. "backwards from the top-ranked one with slack"}
  end
  return {
    kind = "none",
    reason = "plan and ready are at limit with nothing to check — "
    .. "implementation has to catch up before planning adds more",
  }
end

--- The next action for a role.
--- @param items {Item} All items
--- @param role_name string "planner" or "implementer"
--- @return NextAction | nil The decision
--- @return string Error message for an unknown role
local function next_action(items: {Item}, role_name: string): NextAction, string
  if role_name == "implementer" then
    return next_for_implementer(items)
  end
  if role_name == "planner" then
    return next_for_planner(items)
  end
  return nil, "unknown role: " .. tostring(role_name)
  .. " (expected planner or implementer)"
end

local record flow
  type Item = Item
  type Board = Board
  type Index = Index
  type NextAction = NextAction
  LIMITS: {string: integer}
  is_return: function(from: string, to: string): boolean
  admits_over_limit: function(from: string, to: string): boolean
  by_id: function(items: {Item}): Index
  has_open_children: function(items: {Item}, id: string): boolean
  role: function(i: Item, items: {Item}): string
  board: function(items: {Item}): Board
  oldest_first: function(b: Board, phase: string): {Item}
  wip_violations: function(b: Board): {string}
  is_blocked: function(i: Item, index: Index): boolean
  root_of: function(i: Item, index: Index): Item
  item_problems: function(i: Item, items: {Item}, index: Index): {string}
  trace_problems: function(items: {Item}): {string}
  goals: function(items: {Item}): {Item}, {string: boolean}
  findings: function(items: {Item}): {Item}
  next_action: function(items: {Item}, role_name: string): NextAction, string
  ready_gaps: function(body: string): {string}
end

local M: flow = {
  LIMITS = LIMITS,
  is_return = is_return,
  admits_over_limit = admits_over_limit,
  by_id = by_id,
  has_open_children = has_open_children,
  role = role,
  board = board,
  oldest_first = oldest_first,
  wip_violations = wip_violations,
  is_blocked = is_blocked,
  root_of = root_of,
  item_problems = item_problems,
  trace_problems = trace_problems,
  goals = goals,
  findings = findings,
  next_action = next_action,
  ready_gaps = model.ready_gaps,
}

return M
