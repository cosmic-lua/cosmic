--- The simplified flow model over hierarchical items: pure functions
--- from a list of items to decisions, no network and no filesystem.
--- The board is open SLICES grouped by phase — goals, epics, and
--- findings are never phased, so the label board's carve-outs (the
--- epic exemption, the finding exception, the mandated flag) do not
--- exist here; what remains of `admits_over_limit` is two lines. The
--- ready bar (`_work.model.ready_gaps`) is reused as-is over the spec
--- sidecar: the section grammar is the same, only where the prose
--- lives changed. WIP limits carry the same empirically tuned values
--- as `_work.model`; retuning them is a reviewed change here too.
local it = require("_work.item")
local model = require("_work.model")

local type Item = it.Item

--- Open slices grouped by phase name.
local type Board = {string: {Item}}

--- The tool's one answer to "what should I do now".
local record NextAction
  --- "review" | "refine" | "intake" | "finish" | "pull" | "none"
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

--- Whether a full phase admits an arrival anyway. With only slices on
--- the board, two admissions remain: a return, and a move into land —
--- an accept is a decision already made. Everything else queues.
--- @param from string Current phase name, or nil for an entry
--- @param to string Target phase name
--- @return boolean True when the target's WIP limit does not bind
local function admits_over_limit(from: string, to: string): boolean
  return to == "land" or is_return(from, to)
end

--- Items indexed by id.
--- @param items {Item} All items
--- @return {string: Item} The index
local function by_id(items: {Item}): {string: Item}
  local out: {string: Item} = {}
  for _, i in ipairs(items) do
    out[i.id] = i
  end
  return out
end

--- The board: open slices grouped by phase. Everything else — goals,
--- epics, findings, done items — is state the board reasons WITH, not
--- work in a phase.
--- @param items {Item} All items
--- @return Board The board
local function board(items: {Item}): Board
  local out: Board = {}
  for _, i in ipairs(items) do
    if i.kind == "slice" and it.is_open(i) then
      local phase = out[i.phase] or {}
      phase[#phase + 1] = i
      out[i.phase] = phase
    end
  end
  return out
end

--- Slices of one phase, oldest first (opened stamp, then id). Returns
--- a new sorted copy; the board is data, not scratch.
--- @param b Board The board
--- @param phase string Phase name
--- @return {Item} Sorted slices, possibly empty
local function oldest_first(b: Board, phase: string): {Item}
  local list: {Item} = {}
  for _, i in ipairs(b[phase] or {}) do
    list[#list + 1] = i
  end
  table.sort(list, function(x: Item, y: Item): boolean
      if x.opened ~= y.opened then
        return x.opened < y.opened
      end
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

--- Whether an item waits on an open blocker. A blocker id with no item
--- behind it does not block — the board reasons about state it holds.
--- @param i Item The item
--- @param index {string: Item} Items by id
--- @return boolean True when some named blocker is open
local function is_blocked(i: Item, index: {string: Item}): boolean
  for _, b in ipairs(i.blocked_by or {}) do
    local blocker = index[b]
    if blocker ~= nil and it.is_open(blocker) then
      return true
    end
  end
  return false
end

--- Hierarchy problems across the whole tree: parents that do not
--- exist, parents of the wrong kind, and adopted-looking findings.
--- The goal trace stops being prose convention here — a slice reaches
--- a goal through its parent chain or this says so.
--- @param items {Item} All items
--- @return {string} Problems, possibly empty
local function trace_problems(items: {Item}): {string}
  local index = by_id(items)
  local out: {string} = {}
  for _, i in ipairs(items) do
    if (i.parent or "") ~= "" then
      local p = index[i.parent]
      if p == nil then
        out[#out + 1] = ("%s: parent %s does not exist"):format(i.id, i.parent)
      elseif i.kind == "epic" and p.kind ~= "goal" then
        out[#out + 1] = ("%s: an epic's parent must be a goal, %s is a %s")
        :format(i.id, i.parent, p.kind)
      elseif i.kind == "slice" and p.kind ~= "epic" and p.kind ~= "goal" then
        out[#out + 1] = ("%s: a slice's parent must be an epic or goal, "
          .. "%s is a %s"):format(i.id, i.parent, p.kind)
      end
    end
  end
  return out
end

--- The oldest ready slice an implementer may pull: no open blocker.
--- @param b Board The board
--- @param index {string: Item} Items by id
--- @return Item | nil The pullable slice
local function first_pullable(b: Board, index: {string: Item}): Item
  for _, i in ipairs(oldest_first(b, "ready")) do
    if not is_blocked(i, index) then
      return i
    end
  end
  return nil
end

--- The open goals ranked, each with whether live work already drives
--- it (an open epic or slice whose parent chain reaches it).
--- @param items {Item} All items
--- @return {Item} Open goals, rank order
--- @return {string: boolean} goal id -> has live work
local function goals(items: {Item}): {Item}, {string: boolean}
  local index = by_id(items)
  local out: {Item} = {}
  local live: {string: boolean} = {}
  for _, i in ipairs(items) do
    if i.kind == "goal" and it.is_open(i) then
      out[#out + 1] = i
    elseif it.is_open(i) and (i.parent or "") ~= "" then
      local seen = 0
      local p = index[i.parent]
      while p ~= nil and seen < 8 do
        if p.kind == "goal" then
          live[p.id] = true
          break
        end
        seen = seen + 1
        p = index[p.parent or ""]
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

--- The implementer's next action, right to left: land, then do, then
--- pull ready — unless the landing queue is full, when draining it is
--- the action. Same shape as the label board's rule; only the inputs
--- simplified.
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
        #landing, LIMITS["land"], landing[1].id),
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
      reason = "oldest ready slice with no open blocker",
    }
  end
  local waiting = #(b["check"] or {})
  if waiting > 0 then
    return {
      kind = "none",
      reason = ("%d slice(s) await a planner verdict — that verdict is the "
        .. "bottleneck"):format(waiting),
    }
  end
  return {kind = "none", reason = "no ready work — a planner session must "
    .. "refine or intake"}
end

--- The planner's next action: verdicts first, then refine plan toward
--- ready while ready has slack, then intake the top-ranked goal that
--- no live work drives, else nothing.
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
      reason = ("ready holds %d/%d — refine a plan slice toward the bar")
      :format(#(b["ready"] or {}), LIMITS["ready"]),
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
          :format(g.id, g.rank),
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
--- @param role string "planner" or "implementer"
--- @return NextAction | nil The decision
--- @return string Error message for an unknown role
local function next_action(items: {Item}, role: string): NextAction, string
  if role == "implementer" then
    return next_for_implementer(items)
  end
  if role == "planner" then
    return next_for_planner(items)
  end
  return nil, "unknown role: " .. tostring(role)
  .. " (expected planner or implementer)"
end

local record flow
  type Item = Item
  type Board = Board
  type NextAction = NextAction
  LIMITS: {string: integer}
  is_return: function(from: string, to: string): boolean
  admits_over_limit: function(from: string, to: string): boolean
  by_id: function(items: {Item}): {string: Item}
  board: function(items: {Item}): Board
  oldest_first: function(b: Board, phase: string): {Item}
  wip_violations: function(b: Board): {string}
  is_blocked: function(i: Item, index: {string: Item}): boolean
  trace_problems: function(items: {Item}): {string}
  goals: function(items: {Item}): {Item}, {string: boolean}
  next_action: function(items: {Item}, role: string): NextAction, string
  ready_gaps: function(body: string): {string}
end

local M: flow = {
  LIMITS = LIMITS,
  is_return = is_return,
  admits_over_limit = admits_over_limit,
  by_id = by_id,
  board = board,
  oldest_first = oldest_first,
  wip_violations = wip_violations,
  is_blocked = is_blocked,
  trace_problems = trace_problems,
  goals = goals,
  next_action = next_action,
  ready_gaps = model.ready_gaps,
}

return M
