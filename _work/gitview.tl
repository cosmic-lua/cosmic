--- The gitboard read verbs: status, tree, next, show, and find —
--- every verb that renders state without mutating it, split from
--- `_work.gitverbs` (the mutations) so each file stays within the
--- repo's size rule. The verdict-line convention is shared through
--- `_work.gitgate`, so reading the board pulls in no mutation code.
---
--- Each verb is a PURE report over already-read state plus a `cmd_*`
--- that prints it: what a session reads is the contract, and a report
--- that returns its lines can be asserted on without capturing
--- stdout.
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local act = require("_work.action")
local prio = require("_work.priority")
local store = require("_work.store")

local verdict_line = gate.verdict_line

--- The kanban, its per-item marks, and board-wide graph health.
--- Health reports HERE rather than in the ready bar: one item's
--- broken chain is everyone's to see and nobody's reason to be
--- refused a promotion.
---
--- The triage queue counts here too, against its own bound, because
--- a queue past it is the planner's next action.
--- @param all {item.Item} Every item
--- @return {string} The lines to print
--- @return string The verdict detail
local function status_report(all: {item.Item}): {string}, string
  local b = flow.board(all)
  local index = flow.by_id(all)
  local pos = prio.positions(all)
  local out: {string} = {}
  for _, phase in ipairs(item.PHASES) do
    out[#out + 1] = ("%-6s %d/%d"):format(phase, #(b[phase] or {}),
      flow.LIMITS[phase])
    for _, i in ipairs(flow.queued(b, phase, pos)) do
      local marks = ""
      if i.claim ~= "" then marks = marks .. " @" .. i.claim end
      if i.pr ~= 0 then marks = marks .. (" pr:%d"):format(i.pr) end
      if flow.is_blocked(i, index) then marks = marks .. " [blocked]" end
      out[#out + 1] = ("  %s %s%s"):format(i.id:sub(1, 8), i.title, marks)
    end
  end
  -- The triage queue is not a phase, so it carries a count and no
  -- item lines: untriaged roots are not on the board, and `tree` is
  -- where they are listed one by one.
  out[#out + 1] = ("%-6s %d/%d"):format("triage", #flow.untriaged(all),
    flow.TRIAGE_LIMIT)
  local graph = flow.graph_problems(all)
  for _, p in ipairs(graph) do
    out[#out + 1] = "  graph: " .. p
  end
  local verdict = "WIP ok"
  local violations = flow.wip_violations(b)
  local over_triage = flow.triage_violation(all)
  if over_triage then
    violations[#violations + 1] = over_triage
  end
  if #violations > 0 then
    verdict = "WIP: " .. table.concat(violations, "; ")
  end
  if #graph > 0 then
    verdict = ("%s; %d graph problem(s)"):format(verdict, #graph)
  end
  return out, verdict
end

local function cmd_status(s: store.Store): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("status", false, aerr)
  end
  local lines, verdict = status_report(all)
  for _, line in ipairs(lines) do
    print(line)
  end
  return verdict_line("status", true, verdict)
end

--- Render one item's open subtree, indented by depth, into `out`.
--- @param out {string} Lines so far
--- @param all {item.Item} Every item
--- @param parent string The parent id whose children render
--- @param depth integer Current indent depth
--- @param pos {string: prio.Position} Position by item id
local function render_children(out: {string}, all: {item.Item}, parent: string,
    depth: integer, pos: {string: prio.Position})
  if depth > 6 then
    return
  end
  local kids: {item.Item} = {}
  for _, i in ipairs(all) do
    if i.parent == parent and item.is_open(i) then
      kids[#kids + 1] = i
    end
  end
  for _, k in ipairs(prio.sorted(kids, pos)) do
    -- An unphased leaf is NOT a container: it is off the board with
    -- nothing decomposing it, and calling it one would hide that.
    local tag = k.phase
    if tag == "" then
      tag = "container"
      if not flow.has_open_children(all, k.id) then
        tag = "unphased"
      end
    end
    out[#out + 1] = ("%s%s [%s] %s"):format(("  "):rep(depth), k.id:sub(1, 8),
      tag, k.title)
    render_children(out, all, k.id, depth + 1, pos)
  end
end

--- The organizing roots in priority order with their open subtrees,
--- then the triage queue. A root's line carries its standing — how
--- many items it outranks — because that number is the whole of why
--- it sits where it does.
--- @param all {item.Item} Every item
--- @return {string} The lines to print
--- @return string The verdict detail
local function tree_report(all: {item.Item}): {string}, string
  local pos = prio.positions(all)
  local ordered, live = flow.roots(all)
  local out: {string} = {}
  for _, g in ipairs(ordered) do
    local driven = ""
    if not live[g.id] then
      driven = " (no live work)"
    end
    local band = prio.key_of(pos, g.id)
    out[#out + 1] = ("[>%d] %s %s%s"):format(band, g.id:sub(1, 8), g.title,
      driven)
    render_children(out, all, g.id, 1, pos)
  end
  local triage = flow.untriaged(all)
  for _, f in ipairs(triage) do
    local placed = ""
    if not prio.is_placed(pos, f.id) then
      placed = " (unplaced)"
    end
    out[#out + 1] = ("triage %s %s%s"):format(f.id:sub(1, 8), f.title, placed)
  end
  return out, ("%d organizing root(s), %d item(s) awaiting triage"):format(
    #ordered, #triage)
end

local function cmd_tree(s: store.Store): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("tree", false, aerr)
  end
  local lines, verdict = tree_report(all)
  for _, line in ipairs(lines) do
    print(line)
  end
  return verdict_line("tree", true, verdict)
end

--- The one next action for a role, as the verdict detail.
--- @param all {item.Item} Every item
--- @param role string "planner" or "implementer"
--- @param session string This session's name, "" when unnamed
--- @return string | nil The action, its target, and the rule behind it
--- @return string Error message for an unknown role
local function next_report(all: {item.Item}, role: string, session?: string):
  string | nil, string
  local action, nerr = act.for_role(all, role, session)
  if action == nil then
    return nil, nerr
  end
  local target = ""
  if action.item then
    target = (" %s %s"):format(action.item.id:sub(1, 8), action.item.title)
  end
  return ("%s%s — %s"):format(action.kind, target, action.reason)
end

local function cmd_next(s: store.Store, role: string, session?: string): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("next", false, aerr)
  end
  local detail, nerr = next_report(all, role, session)
  if detail == nil then
    return verdict_line("next", false, nerr)
  end
  return verdict_line("next", true, detail)
end

--- One item's fields, role, spec, history, and its own graph
--- problems.
--- @param it item.Item The item
--- @param all {item.Item} Every item
--- @param spec string Its spec sidecar, "" when it has none
--- @param events {store.Event} Its git history, newest first
--- @return {string} The lines to print
--- @return string The verdict detail
local function show_report(it: item.Item, all: {item.Item}, spec: string,
    events: {store.Event}): {string}, string
  local out: {string} = {("%s %s"):format(it.id, it.title)}
  out[#out + 1] = ("role: %s"):format(flow.role(it, all))
  local seconds = ksuid.time_of(it.id)
  if seconds then
    out[#out + 1] = ("opened: %s"):format(
      os.date("!%Y-%m-%dT%H:%M:%SZ", seconds))
  end
  if it.parent ~= "" then out[#out + 1] = ("parent: %s"):format(it.parent) end
  if it.phase ~= "" then out[#out + 1] = ("phase: %s"):format(it.phase) end
  local band, own = prio.key_of(prio.positions(all), it.id)
  if band < 0 then
    out[#out + 1] = "priority: unplaced — nothing has been compared against it"
  else
    out[#out + 1] = ("priority: band %d, outranks %d"):format(band, own)
  end
  if #it.beats > 0 then
    out[#out + 1] = "outranks: " .. table.concat(it.beats, " ")
  end
  if it.claim ~= "" then out[#out + 1] = ("claim: %s"):format(it.claim) end
  if it.pr ~= 0 then out[#out + 1] = ("pr: #%d"):format(it.pr) end
  if it.verdict ~= "" then
    out[#out + 1] = ("verdict: %s (head %s)"):format(it.verdict,
      it.verdict_head)
  end
  if #it.blocked_by > 0 then
    out[#out + 1] = "blocked by: " .. table.concat(it.blocked_by, " ")
  end
  if it.resolution ~= "" then
    out[#out + 1] = ("resolution: %s"):format(it.resolution)
  end
  if spec ~= "" then
    out[#out + 1] = "--- spec ---"
    out[#out + 1] = (spec:gsub("\n$", ""))
  end
  for _, e in ipairs(events) do
    out[#out + 1] = ("  %s %s %s"):format(e.at, e.sha, e.subject)
  end
  for _, p in ipairs(flow.item_problems(it, all, flow.by_id(all))) do
    out[#out + 1] = "  graph: " .. p
  end
  local state = it.phase
  if state == "" then
    state = it.resolution
    if state == "" then
      state = "open"
    end
  end
  return out, ("%s is %s"):format(it.id:sub(1, 8), state)
end

local function cmd_show(s: store.Store, id: string): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("show", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("show", false, aerr)
  end
  local events, herr = store.history(s, id)
  if events == nil then
    return verdict_line("show", false, herr)
  end
  local lines, verdict = show_report(it, all, store.read_spec(s, id), events)
  for _, line in ipairs(lines) do
    print(line)
  end
  return verdict_line("show", true, verdict)
end

--- The longest excerpt text a body line contributes, leaving room
--- for its four-space indent inside the house column width.
local EXCERPT_MAX < const > = 86

--- Whether `hay` contains `needle`, case-insensitively and as plain
--- text. A search term is what a session typed, so it is never a Lua
--- pattern: a term carrying `.` or `%` matches those characters.
--- @param hay string The text searched
--- @param needle string The term, already lowercased
--- @return boolean True when the term occurs
local function contains(hay: string, needle: string): boolean
  return hay:lower():find(needle, 1, true) ~= nil
end

--- What to call a matched item in one word: its phase while it holds
--- one, else the role its graph position gives it, and its
--- resolution once it has ended.
--- @param i item.Item The matched item
--- @param all {item.Item} Every item
--- @return string The tag
local function find_tag(i: item.Item, all: {item.Item}): string
  if not item.is_open(i) then
    return ("done: %s"):format(i.resolution)
  end
  if i.phase ~= "" then
    return i.phase
  end
  return flow.role(i, all)
end

--- The first body line containing `needle`, whitespace-trimmed and
--- truncated to the excerpt width; "" when no line does.
--- @param body string The spec sidecar
--- @param needle string The term, already lowercased
--- @return string The excerpt, possibly empty
local function excerpt_of(body: string, needle: string): string
  for line in body:gmatch("[^\n]+") do
    if contains(line, needle) then
      local text = line:match("^%s*(.-)%s*$")
      if #text > EXCERPT_MAX then
        text = text:sub(1, EXCERPT_MAX - 3) .. "..."
      end
      return text
    end
  end
  return ""
end

--- Every item whose title or spec sidecar contains `text`, oldest
--- first — ids are KSUIDs, so id order is the order they were filed.
---
--- ENDED items are included, tagged with their resolution: the
--- question this answers is whether something has already been
--- filed, and a finding closed as a duplicate answers it exactly as
--- well as an open one does. A match found only in the body carries
--- the line that matched, so the hit is legible without a `show`.
---
--- Sidecars arrive as a map rather than being read here, the way
--- `show_report` takes the one spec it prints: the report stays pure
--- over already-read state, and `cmd_find` owns the store reads.
--- @param all {item.Item} Every item
--- @param specs {string: string} Spec sidecar body, by item id
--- @param text string The term, matched case-insensitively as plain text
--- @return {string} The lines to print
--- @return string The verdict detail
local function find_report(all: {item.Item}, specs: {string: string},
    text: string): {string}, string
  local needle = text:lower()
  local hits: {item.Item} = {}
  for _, i in ipairs(all) do
    if contains(i.title, needle) or contains(specs[i.id] or "", needle) then
      hits[#hits + 1] = i
    end
  end
  table.sort(hits, function(x: item.Item, y: item.Item): boolean
      return x.id < y.id
    end)
  local out: {string} = {}
  for _, i in ipairs(hits) do
    out[#out + 1] = ("%s [%s] %s"):format(i.id:sub(1, 8), find_tag(i, all),
      i.title)
    if not contains(i.title, needle) then
      local ex = excerpt_of(specs[i.id] or "", needle)
      if ex ~= "" then
        out[#out + 1] = "    " .. ex
      end
    end
  end
  return out, ("%d item(s) matching \"%s\""):format(#hits, text)
end

local function cmd_find(s: store.Store, text: string): integer
  if text == "" then
    return verdict_line("find", false, "find needs a search term")
  end
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("find", false, aerr)
  end
  local specs: {string: string} = {}
  for _, i in ipairs(all) do
    specs[i.id] = store.read_spec(s, i.id)
  end
  local lines, verdict = find_report(all, specs, text)
  for _, line in ipairs(lines) do
    print(line)
  end
  return verdict_line("find", true, verdict)
end

local record gitview
  status_report: function(all: {item.Item}): {string}, string
  tree_report: function(all: {item.Item}): {string}, string
  next_report: function(all: {item.Item}, role: string, session?: string):
  string | nil, string
  show_report: function(it: item.Item, all: {item.Item}, spec: string,
  events: {store.Event}): {string}, string
  find_report: function(all: {item.Item}, specs: {string: string},
  text: string): {string}, string
  cmd_status: function(s: store.Store): integer
  cmd_tree: function(s: store.Store): integer
  cmd_next: function(s: store.Store, role: string, session?: string): integer
  cmd_show: function(s: store.Store, id: string): integer
  cmd_find: function(s: store.Store, text: string): integer
end

local M: gitview = {
  status_report = status_report,
  tree_report = tree_report,
  next_report = next_report,
  show_report = show_report,
  find_report = find_report,
  cmd_status = cmd_status,
  cmd_tree = cmd_tree,
  cmd_next = cmd_next,
  cmd_show = cmd_show,
  cmd_find = cmd_find,
}

return M
