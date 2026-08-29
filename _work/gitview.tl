--- The gitboard read verbs: status, tree, next and find — every
--- verb that renders state over the WHOLE board without mutating it,
--- split from `_work.gitverbs` (the mutations) so each file stays
--- within the repo's size rule. `show`, the one read of a single
--- item, is `_work.gitshow` for the same reason. The verdict-line
--- convention is shared through `_work.gitgate`, so reading the board
--- pulls in no mutation code.
---
--- Each verb is a PURE report over already-read state plus a `cmd_*`
--- that prints it: what a session reads is the contract, and a report
--- that returns its lines can be asserted on without capturing
--- stdout.
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local guide = require("_work.guidance")
local health = require("_work.health")
local item = require("_work.item")
local act = require("_work.action")
local prio = require("_work.priority")
local sess = require("_work.session")
local store = require("_work.store")

local verdict_line = gate.verdict_line

--- Seconds since each claimed item's last board commit, read from git
--- once per render. Only claimed items are asked about — staleness is
--- a property of a claim — so the cost is a handful of `git log -1`
--- calls, not one per item on the board.
--- @param s store.Store The store
--- @param all {item.Item} Every item
--- @return health.Ages Ages by item id
local function claim_ages(s: store.Store, all: {item.Item}): health.Ages
  local ages: health.Ages = {}
  local now = os.time()
  for _, i in ipairs(all) do
    if item.is_open(i)
    and ((i.claim or "") ~= "" or (i.reviewer or "") ~= "") then
      local t = store.touched_at(s, i.id)
      if t ~= nil and t <= now then
        ages[i.id] = now - t
      end
    end
  end
  return ages
end

--- Every spec sidecar, by item id, for the bar checks the reports
--- run. Read once per render; the reports stay pure over the map.
--- @param s store.Store The store
--- @param all {item.Item} Every item
--- @return act.Specs Sidecar body by id
local function read_specs(s: store.Store, all: {item.Item}): act.Specs
  local out: act.Specs = {}
  for _, i in ipairs(all) do
    if item.is_open(i) then
      out[i.id] = store.read_spec(s, i.id)
    end
  end
  return out
end

--- How many todo lines status renders item-by-item. The top of the
--- queue is what a session acts on; the rest is the count.
local TODO_SHOWN < const >: integer = 8

--- The board: doing item by item against the one bound, the top of
--- todo with its pullable marks, the triage depth, and board-wide
--- graph health. Health reports HERE rather than in the spec bar:
--- one item's broken chain is everyone's to see and nobody's reason
--- to be refused a take.
--- @param all {item.Item} Every item
--- @param specs act.Specs Sidecar body by id
--- @param ages health.Ages Seconds since last board commit, by id
--- @return {string} The lines to print
--- @return string The verdict detail
local function status_report(all: {item.Item}, specs: act.Specs,
    ages?: health.Ages): {string}, string
  local aged = ages or {}
  local index = flow.by_id(all)
  local pos = prio.positions(all)
  local out: {string} = {}
  local doing = flow.in_state(all, "doing", pos)
  out[#out + 1] = ("%-6s %d/%d"):format("doing", #doing, flow.DOING_LIMIT)
  for _, i in ipairs(doing) do
    local marks = (" [%s]"):format(flow.substate(i))
    if i.claim ~= "" then marks = marks .. " @" .. i.claim end
    if i.pr ~= 0 then marks = marks .. (" pr:%d"):format(i.pr) end
    if flow.is_blocked(i, index) then marks = marks .. " [blocked]" end
    if i.repo ~= "" then marks = marks .. " [" .. i.repo .. "]" end
    if health.is_stale(i, aged) then
      marks = marks .. (" [claim stale %dh]"):format(
        health.stale_hours(i, aged))
    end
    out[#out + 1] = ("  %s %s%s"):format(i.id:sub(1, 8), i.title, marks)
  end
  local todo = flow.in_state(all, "todo", pos)
  local pullable = 0
  for _, i in ipairs(todo) do
    if act.passes_bar(i, specs, pos) and not flow.is_blocked(i, index) then
      pullable = pullable + 1
    end
  end
  out[#out + 1] = ("%-6s %d (%d pullable)"):format("todo", #todo, pullable)
  for k = 1, math.min(#todo, TODO_SHOWN) do
    local i = todo[k]
    local marks = ""
    if act.passes_bar(i, specs, pos) then
      marks = " [pullable]"
    end
    if flow.is_blocked(i, index) then marks = marks .. " [blocked]" end
    if i.repo ~= "" then marks = marks .. " [" .. i.repo .. "]" end
    out[#out + 1] = ("  %s %s%s"):format(i.id:sub(1, 8), i.title, marks)
  end
  if #todo > TODO_SHOWN then
    out[#out + 1] = ("  ... %d more"):format(#todo - TODO_SHOWN)
  end
  -- The triage queue carries a count and no item lines: untriaged
  -- roots are not workable yet, and `tree` is where they are listed
  -- one by one.
  out[#out + 1] = ("%-6s %d"):format("triage", #flow.untriaged(all))
  local graph = flow.graph_problems(all)
  for _, p in ipairs(health.blocker_cycle_problems(all)) do
    graph[#graph + 1] = p
  end
  for _, p in ipairs(graph) do
    out[#out + 1] = "  graph: " .. p
  end
  local verdict = ("doing %d/%d"):format(#doing, flow.DOING_LIMIT)
  local bound = flow.doing_refusal(all)
  if bound then
    verdict = "bound: " .. bound
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
  local lines, verdict = status_report(all, read_specs(s, all),
    claim_ages(s, all))
  for _, line in ipairs(lines) do
    print(line)
  end
  -- Who the board thinks this session is, printed rather than
  -- documented: the identity decides which work is withheld and which
  -- verdicts are refused, so a session that cannot see it cannot tell
  -- a healthy board from one that has stopped offering it anything.
  print(sess.note(sess.resolve(nil)))
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
    local tag = "container"
    if not flow.has_open_children(all, k.id) then
      tag = flow.is_doing(k) and flow.substate(k) or "todo"
    end
    local repo = ""
    if k.repo ~= "" then repo = " [" .. k.repo .. "]" end
    out[#out + 1] = ("%s%s [%s] %s%s"):format(("  "):rep(depth), k.id:sub(1, 8),
      tag, k.title, repo)
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

--- The one next action, as the verdict detail. Acting on it moves
--- the board, so a session taking several asks again after each one
--- rather than reading a list. A `none` names the fact that binds,
--- which is the diagnosis a session reports.
---
--- Under that line, indented, is what the kind MEANS
--- (`_work.guidance`): the verb that performs it and the ordering
--- rule behind it, so a session acts on the answer without going to
--- read prose elsewhere.
--- @param all {item.Item} Every item
--- @param specs act.Specs Sidecar body by id
--- @param session string This session's name, "" when unnamed
--- @param ages health.Ages Seconds since last board commit, by id
--- @return string The action, its target, the rule behind it, and its guidance
local function next_report(all: {item.Item}, specs: act.Specs,
    session?: string, ages?: health.Ages): string
  -- The session seeds the tie-break, so concurrent sessions asking
  -- the same board fan out across items no judgment separates
  -- instead of converging on one.
  local action = act.next_action(all, specs, session, ages, session)
  local target = ""
  if action.item then
    target = (" %s %s"):format(action.item.id:sub(1, 8), action.item.title)
  end
  local out: {string} = {
    ("%s%s — %s"):format(action.kind, target, action.reason),
  }
  for _, line in ipairs(guide.lines(action.kind)) do
    out[#out + 1] = "  " .. line
  end
  for _, alt in ipairs(action.alternates or {}) do
    if alt.item then
      out[#out + 1] = ("  or: %s %s %s"):format(alt.kind,
        alt.item.id:sub(1, 8), alt.item.title)
    end
  end
  return table.concat(out, "\n")
end

local function cmd_next(s: store.Store, session?: string): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("next", false, aerr)
  end
  return verdict_line("next", true,
    next_report(all, read_specs(s, all), session, claim_ages(s, all)))
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

--- What to call a matched item in one word: its resolution once it
--- has ended, its state while workable, else the role its graph
--- position gives it.
--- @param i item.Item The matched item
--- @param all {item.Item} Every item
--- @return string The tag
local function find_tag(i: item.Item, all: {item.Item}): string
  if not item.is_open(i) then
    return ("done: %s"):format(i.resolution)
  end
  if flow.role(i, all) == "work" then
    return flow.is_doing(i) and flow.substate(i) or "todo"
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
--- Sidecars arrive as a map rather than being read here: the report
--- stays pure over already-read state, and `cmd_find` owns the store
--- reads.
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

--- The spec bar asked of one item: is it workable and placed, does
--- its spec fill the required sections, is its chain traceable. A
--- READ — it prints the same problem list `take` enforces and changes
--- nothing — so it lives with the reads rather than with the verbs
--- whose gate it shares.
--- @param s store.Store The store
--- @param id string The item id or an unambiguous prefix
--- @return integer Exit code
local function cmd_check(s: store.Store, id: string): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("check", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("check", false, aerr)
  end
  local problems = gate.ready_problems(s, it, all)
  for _, p in ipairs(problems) do
    print("  " .. p)
  end
  if #problems > 0 then
    return verdict_line("check", false,
      ("%s misses the spec bar (%d problem(s))"):format(id:sub(1, 8),
        #problems))
  end
  return verdict_line("check", true,
    ("%s meets the spec bar"):format(id:sub(1, 8)))
end

local record gitview
  status_report: function(all: {item.Item}, specs: act.Specs,
  ages?: health.Ages): {string}, string
  tree_report: function(all: {item.Item}): {string}, string
  next_report: function(all: {item.Item}, specs: act.Specs,
  session?: string, ages?: health.Ages): string
  find_report: function(all: {item.Item}, specs: {string: string},
  text: string): {string}, string
  read_specs: function(s: store.Store, all: {item.Item}): act.Specs
  cmd_status: function(s: store.Store): integer
  cmd_tree: function(s: store.Store): integer
  cmd_next: function(s: store.Store, session?: string): integer
  cmd_find: function(s: store.Store, text: string): integer
  cmd_check: function(s: store.Store, id: string): integer
end

local M: gitview = {
  status_report = status_report,
  tree_report = tree_report,
  next_report = next_report,
  find_report = find_report,
  read_specs = read_specs,
  cmd_status = cmd_status,
  cmd_tree = cmd_tree,
  cmd_next = cmd_next,
  cmd_find = cmd_find,
  cmd_check = cmd_check,
}

return M
