--- The gitboard read verbs: status, tree, next, and show — every
--- verb that renders state without mutating it, split from
--- `_work.gitverbs` (the mutations) so each file stays within the
--- repo's size rule. The verdict-line convention is shared through
--- gitverbs.
local flow = require("_work.flow")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

local verdict_line = verbs.verdict_line

local function cmd_status(s: store.Store): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("status", false, aerr)
  end
  local b = flow.board(all)
  local index = flow.by_id(all)
  for _, phase in ipairs(item.PHASES) do
    print(("%-6s %d/%d"):format(phase, #(b[phase] or {}), flow.LIMITS[phase]))
    for _, i in ipairs(flow.oldest_first(b, phase)) do
      local marks = ""
      if i.claim ~= "" then marks = marks .. " @" .. i.claim end
      if i.pr ~= 0 then marks = marks .. (" pr:%d"):format(i.pr) end
      if flow.is_blocked(i, index) then marks = marks .. " [blocked]" end
      print(("  %s %s%s"):format(i.id:sub(1, 8), i.title, marks))
    end
  end
  local violations = flow.wip_violations(b)
  if #violations > 0 then
    return verdict_line("status", true,
      "WIP: " .. table.concat(violations, "; "))
  end
  return verdict_line("status", true, "WIP ok")
end

--- Render one item's open subtree, indented by depth.
--- @param all {item.Item} Every item
--- @param parent string The parent id whose children render
--- @param depth integer Current indent depth
local function render_children(all: {item.Item}, parent: string, depth: integer)
  if depth > 6 then
    return
  end
  local kids: {item.Item} = {}
  for _, i in ipairs(all) do
    if i.parent == parent and item.is_open(i) then
      kids[#kids + 1] = i
    end
  end
  table.sort(kids, function(x: item.Item, y: item.Item): boolean
      return x.id < y.id
    end)
  for _, k in ipairs(kids) do
    local tag = k.phase
    if tag == "" then
      tag = "container"
    end
    print(("%s%s [%s] %s"):format(("  "):rep(depth), k.id:sub(1, 8), tag,
        k.title))
    render_children(all, k.id, depth + 1)
  end
end

local function cmd_tree(s: store.Store): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("tree", false, aerr)
  end
  local ranked, live = flow.goals(all)
  for _, g in ipairs(ranked) do
    local driven = ""
    if not live[g.id] then
      driven = " (no live work)"
    end
    print(("G%d %s %s%s"):format(g.rank, g.id:sub(1, 8), g.title, driven))
    render_children(all, g.id, 1)
  end
  local triage = flow.findings(all)
  for _, f in ipairs(triage) do
    print(("finding %s %s"):format(f.id:sub(1, 8), f.title))
    render_children(all, f.id, 1)
  end
  return verdict_line("tree", true,
    ("%d open goal(s), %d finding(s) awaiting triage"):format(
      #ranked, #triage))
end

local function cmd_next(s: store.Store, role: string): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("next", false, aerr)
  end
  local action, nerr = flow.next_action(all, role)
  if action == nil then
    return verdict_line("next", false, nerr)
  end
  local target = ""
  if action.item then
    target = (" %s %s"):format(action.item.id:sub(1, 8), action.item.title)
  end
  return verdict_line("next", true,
    ("%s%s — %s"):format(action.kind, target, action.reason))
end

local function cmd_show(s: store.Store, id: string): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("show", false, lerr)
  end
  local all = store.list(s)
  print(("%s %s"):format(it.id, it.title))
  if all then
    print(("role: %s"):format(flow.role(it, all)))
  end
  local seconds = ksuid.time_of(it.id)
  if seconds then
    print(("opened: %s"):format(os.date("!%Y-%m-%dT%H:%M:%SZ", seconds)))
  end
  if it.parent ~= "" then print(("parent: %s"):format(it.parent)) end
  if it.phase ~= "" then print(("phase: %s"):format(it.phase)) end
  if it.rank ~= 0 then print(("rank: %d"):format(it.rank)) end
  if it.claim ~= "" then print(("claim: %s"):format(it.claim)) end
  if it.pr ~= 0 then print(("pr: #%d"):format(it.pr)) end
  if it.verdict ~= "" then
    print(("verdict: %s (head %s)"):format(it.verdict, it.verdict_head))
  end
  if #it.blocked_by > 0 then
    print("blocked by: " .. table.concat(it.blocked_by, " "))
  end
  if it.resolution ~= "" then
    print(("resolution: %s"):format(it.resolution))
  end
  local spec = store.read_spec(s, id)
  if spec ~= "" then
    print("--- spec ---")
    io.write(spec)
  end
  local events = store.history(s, id)
  if events then
    for _, e in ipairs(events) do
      print(("  %s %s %s"):format(e.at, e.sha, e.subject))
    end
  end
  local state = it.phase
  if state == "" then
    state = it.resolution
    if state == "" then
      state = "open"
    end
  end
  return verdict_line("show", true, ("%s is %s"):format(id:sub(1, 8), state))
end

local record gitview
  cmd_status: function(s: store.Store): integer
  cmd_tree: function(s: store.Store): integer
  cmd_next: function(s: store.Store, role: string): integer
  cmd_show: function(s: store.Store, id: string): integer
end

local M: gitview = {
  cmd_status = cmd_status,
  cmd_tree = cmd_tree,
  cmd_next = cmd_next,
  cmd_show = cmd_show,
}

return M
