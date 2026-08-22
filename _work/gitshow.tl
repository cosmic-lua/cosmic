--- The `show` verb: one item rendered, whole or narrowed. Its own
--- module rather than a fifth report inside `_work.gitview`, which
--- sits against the repo's 500-line rule with the four it carries.
---
--- A ready-bar spec is long BY DESIGN — it has to be implementable
--- from its own text — so what narrows is the read, not the spec.
--- `--spec` prints the sidecar alone, `--section NAME` one of its
--- sections, `--fields` the record without prose; the default output
--- is unchanged, so a session that wants everything asks for nothing.
--- The section grammar is `_work.spec`'s, the same one the ready bar
--- lints against, so a selector needs no parsing of its own.
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

--- The four reads `show` offers. Anything else reaching `cmd_show` is
--- more than one narrowing flag at once, which names no single read.
local MODES: {string: boolean} = {
  [""] = true, ["spec"] = true, ["section"] = true, ["fields"] = true,
}

--- One word for where an item stands: its phase while it holds one,
--- else how it ended, else that it is merely open.
--- @param it item.Item The item
--- @return string The state
local function state_of(it: item.Item): string
  local state = it.phase
  if state == "" then
    state = it.resolution
    if state == "" then
      state = "open"
    end
  end
  return state
end

--- One item's fields, role, spec, history, and its own graph
--- problems. Under `fields` the two prose blocks — the sidecar and
--- the git history — are left out; everything else renders the same,
--- because the questions `--fields` answers (what phase, whose claim,
--- which PR, what is it waiting on) are the record's to answer.
--- @param it item.Item The item
--- @param all {item.Item} Every item
--- @param body string Its spec sidecar, "" when it has none
--- @param events {store.Event} Its git history, newest first
--- @param mode string "" for the whole report, "fields" for the record
--- @return {string} The lines to print
--- @return string The verdict detail
local function show_report(it: item.Item, all: {item.Item}, body: string,
    events: {store.Event}, mode?: string): {string}, string
  local bare = (mode or "") == "fields"
  local out: {string} = {("%s %s"):format(it.id, it.title)}
  out[#out + 1] = ("role: %s"):format(flow.role(it, all))
  local seconds = ksuid.time_of(it.id)
  if seconds then
    out[#out + 1] = ("opened: %s"):format(
      os.date("!%Y-%m-%dT%H:%M:%SZ", seconds))
  end
  if it.parent ~= "" then out[#out + 1] = ("parent: %s"):format(it.parent) end
  if it.repo ~= "" then out[#out + 1] = ("repo: %s"):format(it.repo) end
  if it.phase ~= "" then out[#out + 1] = ("phase: %s"):format(it.phase) end
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
  if it.pr ~= 0 then out[#out + 1] = ("pr: #%d"):format(it.pr) end
  if it.verdict ~= "" then
    out[#out + 1] = ("verdict: %s (head %s)"):format(it.verdict,
      it.verdict_head)
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
  if body ~= "" and not bare then
    out[#out + 1] = "--- spec ---"
    out[#out + 1] = (body:gsub("\n$", ""))
  end
  if not bare then
    for _, e in ipairs(events) do
      out[#out + 1] = ("  %s %s %s"):format(e.at, e.sha, e.subject)
    end
  end
  for _, p in ipairs(flow.item_problems(it, all, flow.by_id(all))) do
    out[#out + 1] = "  graph: " .. p
  end
  return out, ("%s is %s"):format(it.id:sub(1, 8), state_of(it))
end

--- The sidecar prose a narrowed read prints: the whole body, or the
--- one section `section` names with its heading line.
---
--- Returns nil rather than an empty list for both ways the read can
--- have nothing to show, because the two are different answers: an
--- item with no sidecar at all, and a sidecar that does not carry the
--- section asked for.
--- @param it item.Item The item, for the ids in the messages
--- @param body string Its spec sidecar, "" when it has none
--- @param section string The section to narrow to, "" for the whole body
--- @return {string} | nil The lines to print
--- @return string Why there are none
local function spec_lines(it: item.Item, body: string,
    section: string): {string} | nil, string
  if body == "" then
    return nil, ("%s has no spec"):format(it.id:sub(1, 8))
  end
  local text = body
  if section ~= "" then
    text = spec.section_of(body, section)
    if text == "" then
      return nil, ("%s spec has no section: %s"):format(it.id:sub(1, 8), section)
    end
  end
  local out: {string} = {}
  for line in (text:gsub("\n$", "")):gmatch("([^\n]*)") do
    out[#out + 1] = line
  end
  return out, ""
end

--- Print one item: the whole report, or the one narrowing `mode`
--- names. A mode outside the four is more than one narrowing flag at
--- once — which names no single read, so it is refused rather than
--- resolved by precedence.
--- @param s store.Store The store
--- @param id string The item id or an unambiguous prefix
--- @param mode string "", "spec", "section" or "fields"
--- @param section string The section name, when mode is "section"
--- @return integer Exit code
local function cmd_show(s: store.Store, id: string, mode?: string,
    section?: string): integer
  local want = mode or ""
  if not MODES[want] then
    return verdict_line("show", false,
      "REFUSED: --spec, --section and --fields each narrow one read — pass one")
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("show", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("show", false, aerr)
  end
  local body = store.read_spec(s, id)
  if want == "spec" or want == "section" then
    local lines, why = spec_lines(it, body,
      want == "section" and (section or "") or "")
    if lines == nil then
      return verdict_line("show", false, why)
    end
    for _, line in ipairs(lines) do
      print(line)
    end
    return verdict_line("show", true,
      ("%s is %s"):format(it.id:sub(1, 8), state_of(it)))
  end
  local events: {store.Event} = {}
  if want == "" then
    local read, herr = store.history(s, id)
    if read == nil then
      return verdict_line("show", false, herr)
    end
    events = read
  end
  local lines, verdict = show_report(it, all, body, events, want)
  for _, line in ipairs(lines) do
    print(line)
  end
  return verdict_line("show", true, verdict)
end

local record gitshow
  show_report: function(it: item.Item, all: {item.Item}, body: string,
  events: {store.Event}, mode?: string): {string}, string
  spec_lines: function(it: item.Item, body: string,
  section: string): {string} | nil, string
  cmd_show: function(s: store.Store, id: string, mode?: string,
  section?: string): integer
end

local M: gitshow = {
  show_report = show_report,
  spec_lines = spec_lines,
  cmd_show = cmd_show,
}

return M
