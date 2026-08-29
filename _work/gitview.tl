--- The board-wide reads behind `show` (bare) and `next`, split from
--- `_work.gitverbs` (the mutations) so each file stays within the
--- repo's size rule. `show ID`, the read of a single item, is
--- `_work.gitshow` for the same reason. The verdict-line convention
--- is shared through `_work.gitgate`, so reading the board pulls in
--- no mutation code.
---
--- Each read is a PURE report over already-read state plus a `cmd_*`
--- that prints it: what a session reads is the contract, and a report
--- that returns its lines can be asserted on without capturing
--- stdout.
local alias = require("_work.alias")
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

--- How many todo lines the board render shows item-by-item. The top
--- of the queue is what a session acts on; the rest is the count.
local TODO_SHOWN < const >: integer = 8

--- The id and title every rendered item line leads with: the id8
--- chunked for legibility, the derived alias bracketed after the
--- title so a session reading the board can retype either back.
--- @param it item.Item The item
--- @return string "id8-chunked title [alias]"
local function id_line(it: item.Item): string
  return ("%s %s [%s]"):format(alias.chunk(it.id:sub(1, 8)), it.title,
    alias.of(it.id))
end

--- The board: doing item by item against the one bound, the top of
--- todo with its pullable marks, the triage queue, and board-wide
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
    out[#out + 1] = ("  %s%s"):format(id_line(i), marks)
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
    out[#out + 1] = ("  %s%s"):format(id_line(i), marks)
  end
  if #todo > TODO_SHOWN then
    out[#out + 1] = ("  ... %d more"):format(#todo - TODO_SHOWN)
  end
  -- Untriaged roots render item by item: they are not workable yet,
  -- and this is the one list of them anyone gets.
  local triage = flow.untriaged(all)
  out[#out + 1] = ("%-6s %d"):format("triage", #triage)
  for _, f in ipairs(triage) do
    out[#out + 1] = ("  %s %s"):format(f.id:sub(1, 8), f.title)
  end
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

--- Bare `show`: the whole board. Named `cmd_status` for the report it
--- prints; the verdict line says `show`, the verb that reaches it.
local function cmd_status(s: store.Store): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("show", false, aerr)
  end
  local lines, verdict = status_report(all, read_specs(s, all),
    claim_ages(s, all))
  for _, line in ipairs(lines) do
    print(line)
  end
  -- Who the board thinks this session is, printed rather than
  -- documented: the identity decides which work is withheld and which
  -- claims are refused, so a session that cannot see it cannot tell
  -- a healthy board from one that has stopped offering it anything.
  print(sess.note(sess.resolve(nil)))
  return verdict_line("show", true, verdict)
end

--- Renders a decided action: what to do, to what, and under which
--- rule, followed by what the kind MEANS (`_work.guidance`) and any
--- alternates — so a session acts on the answer without going to read
--- prose elsewhere.
--- @param action act.Action The decision
--- @return string The action, its target, the rule behind it, and its guidance
local function render_action(action: act.Action): string
  local target = ""
  if action.item then
    target = " " .. id_line(action.item)
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

--- The one next action, as the verdict detail. Acting on it moves
--- the board, so a session taking several asks again after each one
--- rather than reading a list. A `none` names the fact that binds,
--- which is the diagnosis a session reports.
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
  return render_action(act.next_action(all, specs, session, ages, session))
end

--- The gap named by an item's most recent board commit, when that
--- commit was a bounce (`drop ID: <why>`) rather than a take or a
--- reviewer's release (`drop ID review: <why>` — the review comes
--- free again, but the build was never dropped).
--- @param subject string The most recent board-commit subject
--- @return string " (last bounce: <why>)", or "" when it was not one
local function bounce_note(subject: string): string
  local why = subject:match("^drop %S+: (.+)$")
  if why == nil then
    return ""
  end
  return (" (last bounce: %s)"):format(why)
end

--- `next_report`, but for a decided `pull` the reason carries the gap
--- named by the item's last bounce, read once for the one decided
--- action rather than once per candidate: a session that dropped an
--- item and asks again starts from the recorded gap instead of
--- re-discovering it.
--- @param s store.Store The store
--- @param all {item.Item} Every item
--- @param specs act.Specs Sidecar body by id
--- @param session string This session's name, "" when unnamed
--- @param ages health.Ages Seconds since last board commit, by id
--- @return string The action, its target, the rule behind it, and its guidance
local function next_report_live(s: store.Store, all: {item.Item},
    specs: act.Specs, session?: string, ages?: health.Ages): string
  local action = act.next_action(all, specs, session, ages, session)
  if action.kind == "pull" and action.item then
    local events = store.history(s, action.item.id)
    if events and events[1] then
      action.reason = action.reason .. bounce_note(events[1].subject)
    end
  end
  return render_action(action)
end

local function cmd_next(s: store.Store, session?: string): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("next", false, aerr)
  end
  return verdict_line("next", true,
    next_report_live(s, all, read_specs(s, all), session, claim_ages(s, all)))
end

local record gitview
  status_report: function(all: {item.Item}, specs: act.Specs,
  ages?: health.Ages): {string}, string
  next_report: function(all: {item.Item}, specs: act.Specs,
  session?: string, ages?: health.Ages): string
  next_report_live: function(s: store.Store, all: {item.Item},
  specs: act.Specs, session?: string, ages?: health.Ages): string
  bounce_note: function(subject: string): string
  read_specs: function(s: store.Store, all: {item.Item}): act.Specs
  cmd_status: function(s: store.Store): integer
  cmd_next: function(s: store.Store, session?: string): integer
end

local M: gitview = {
  status_report = status_report,
  next_report = next_report,
  next_report_live = next_report_live,
  bounce_note = bounce_note,
  read_specs = read_specs,
  cmd_status = cmd_status,
  cmd_next = cmd_next,
}

return M
