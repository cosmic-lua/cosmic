--- The `show ID` verb: one item rendered whole — fields, derived
--- state, priority standing, blockers, spec, history, and the same
--- problem list `take` enforces as its spec bar, so what would refuse
--- a pull is visible on the read that precedes it. Its own module
--- rather than a third report inside `_work.gitview`, which sits
--- against the repo's 500-line rule.
---
--- Like every read verb, the report is PURE over already-read state
--- and the `cmd_` half owns the store reads: what a session reads is
--- the contract, and a report that returns its lines can be asserted
--- on without capturing stdout.
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local prio = require("_work.priority")
local spec = require("_work.spec")
local store = require("_work.store")

local verdict_line = gate.verdict_line

--- One word for where an item stands: how it ended, else its derived
--- state while in flight, else todo.
--- @param it item.Item The item
--- @return string The state
local function state_of(it: item.Item): string
  if (it.resolution or "") ~= "" then
    return it.resolution
  end
  if flow.is_doing(it) then
    return flow.substate(it)
  end
  return "todo"
end

--- One item's fields, role, spec, spec-bar problems, and history.
--- @param it item.Item The item
--- @param all {item.Item} Every item
--- @param body string Its spec sidecar, "" when it has none
--- @param events {store.Event} Its git history, newest first
--- @param problems {string} The take gate's problem list, possibly empty
--- @return {string} The lines to print
--- @return string The verdict detail
local function show_report(it: item.Item, all: {item.Item}, body: string,
    events: {store.Event}, problems: {string}): {string}, string
  local out: {string} = {("%s %s"):format(it.id, it.title)}
  out[#out + 1] = ("role: %s"):format(flow.role(it, all))
  local seconds = ksuid.time_of(it.id)
  if seconds then
    out[#out + 1] = ("opened: %s"):format(
      os.date("!%Y-%m-%dT%H:%M:%SZ", seconds))
  end
  if it.parent ~= "" then out[#out + 1] = ("parent: %s"):format(it.parent) end
  if it.repo ~= "" then out[#out + 1] = ("repo: %s"):format(it.repo) end
  if item.is_open(it) and flow.role(it, all) == "work" then
    out[#out + 1] = ("state: %s"):format(state_of(it))
  end
  local at = prio.positions(all)
  local band, own = prio.key_of(at, it.id)
  if band < 0 then
    out[#out + 1] = "priority: unplaced — nothing has been compared against it"
  else
    out[#out + 1] = ("priority: band %d, outranks %d"):format(band, own)
  end
  -- `priority` is what was RECORDED; this is what orders the item when
  -- a blocker edge moved it off that. A session reading a queue has to
  -- be able to see why something sorted where it did, or a lift reads
  -- as a bug in the sort.
  local lift_band, _lift_own, frees = prio.order_of(at, it.id)
  if frees > 0 then
    local from = ""
    local source = (at[it.id] or {}).lifted_from or ""
    if source ~= "" then
      from = (", ordered at band %d for %s"):format(lift_band,
        source:sub(1, 8))
    end
    out[#out + 1] = ("unblocks: %d open item(s)%s"):format(frees, from)
  end
  if #it.beats > 0 then
    out[#out + 1] = "outranks: " .. table.concat(it.beats, " ")
  end
  if it.claim ~= "" then out[#out + 1] = ("claim: %s"):format(it.claim) end
  if it.reviewer ~= "" then
    out[#out + 1] = ("reviewer: %s"):format(it.reviewer)
  end
  if it.pr ~= 0 then out[#out + 1] = ("pr: #%d"):format(it.pr) end
  if it.verdict ~= "" then
    -- A verdict judges a head AND the spec that head is measured
    -- against, so the head alone cannot answer the question a
    -- re-reviewer asks here: is there anything new to see? A rework
    -- that answers a bounce on the spec moves the sidecar and no
    -- commit, and reading an unmoved head as "nothing happened" is
    -- exactly the mistake. An unrecorded revision says nothing rather
    -- than guessing: the line then reads as it always did.
    local moved = ""
    if (it.verdict_spec or "") ~= "" then
      moved = ", spec unchanged since"
      if spec.revision(body) ~= it.verdict_spec then
        moved = ", spec changed since"
      end
    end
    out[#out + 1] = ("verdict: %s (head %s%s)"):format(it.verdict,
      it.verdict_head, moved)
  end
  -- Which edges still bind is `flow.binds`, the same predicate
  -- `flow.is_blocked` is built from, so this heading, the `[blocked]`
  -- mark and `next`'s skipping cannot disagree about what holds an
  -- item up. The cleared half is printed too: it is the record of what
  -- this item waited on.
  local index = flow.by_id(all)
  local binding: {string} = {}
  local cleared: {string} = {}
  for _, b in ipairs(it.blocked_by) do
    if flow.binds(index, b) then
      binding[#binding + 1] = b
    else
      cleared[#cleared + 1] = b
    end
  end
  if #binding > 0 then
    out[#out + 1] = "blocked by: " .. table.concat(binding, " ")
    for _, b in ipairs(binding) do
      local why = (it.block_reason or {})[b]
      if why ~= nil and why ~= "" then
        out[#out + 1] = ("  %s: %s"):format(b:sub(1, 8), why)
      end
    end
  end
  if #cleared > 0 then
    out[#out + 1] = "blockers cleared: " .. table.concat(cleared, " ")
  end
  if it.resolution ~= "" then
    out[#out + 1] = ("resolution: %s"):format(it.resolution)
  end
  -- The take gate's own problem list, printed on the read that
  -- precedes the pull: what would refuse `take` is nobody's surprise.
  for _, p in ipairs(problems) do
    out[#out + 1] = "bar: " .. p
  end
  if body ~= "" then
    out[#out + 1] = "--- spec ---"
    out[#out + 1] = (body:gsub("\n$", ""))
  end
  for _, e in ipairs(events) do
    out[#out + 1] = ("  %s %s %s"):format(e.at, e.sha, e.subject)
  end
  return out, ("%s is %s"):format(it.id:sub(1, 8), state_of(it))
end

--- Print one item.
--- @param s store.Store The store
--- @param id string The item id or an unambiguous prefix
--- @return integer Exit code
local function cmd_show(s: store.Store, id: string): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("show", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("show", false, aerr)
  end
  local body = store.read_spec(s, id)
  local events, herr = store.history(s, id)
  if events == nil then
    return verdict_line("show", false, herr)
  end
  local problems: {string} = {}
  if item.is_open(it) then
    problems = gate.ready_problems(s, it, all)
  end
  local lines, verdict = show_report(it, all, body, events, problems)
  for _, line in ipairs(lines) do
    print(line)
  end
  return verdict_line("show", true, verdict)
end

local record gitshow
  show_report: function(it: item.Item, all: {item.Item}, body: string,
  events: {store.Event}, problems: {string}): {string}, string
  cmd_show: function(s: store.Store, id: string): integer
end

local M: gitshow = {
  show_report = show_report,
  cmd_show = cmd_show,
}

return M
