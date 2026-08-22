--- Flow measurement over the board's own commit log: how long items
--- dwell in each phase, and how often each transition happens. Every
--- board mutation is one commit with a structured subject, so the log
--- IS the flow record and nothing else has to be kept.
---
--- Three subjects carry a transition — `move`, `verdict` and `done` —
--- matched by ANCHORED, shape-driven patterns. The branch also carries
--- squash-merge commits whose PR titles open with a verb name
--- (`verdict: an accept reads the request it judges`), so a substring
--- search would ingest those and corrupt every number here. The report
--- is PURE over parsed transitions and `cmd_stats` prints it, so what
--- a session reads can be asserted without stdout.
local gate = require("_work.gitgate")
local item = require("_work.item")
local store = require("_work.store")

local verdict_line = gate.verdict_line

--- One phase change of one item, as a commit recorded it.
local record Transition
  id: string
  --- ISO 8601 commit time.
  at: string
  --- Phase left; for a `done`, the phase the item ended from.
  from: string
  --- Phase entered, "" when the item ended.
  to: string
  --- The kind for a `verdict`, the resolution for a `done`, "" for a
  --- plain `move`.
  verdict: string
end

--- How long items sit in one phase, over every dwell that has ENDED.
local record Dwell
  phase: string
  --- Completed dwells measured; an item still in the phase is not one.
  entries: integer
  --- Nearest-rank percentiles: observations, never interpolations.
  median_s: integer
  p90_s: integer
end

--- One transition with the facts ordering it needs.
local record Timed
  t: Transition
  at_s: integer
  --- Arrival position, the tiebreak for equal commit times.
  idx: integer
end

--- Days from 1970-01-01 to a proleptic Gregorian date.
--- @param y integer Year
--- @param m integer Month, 1-12
--- @param d integer Day of month
--- @return integer Days since the epoch, negative before it
local function days_from_civil(y: integer, m: integer, d: integer): integer
  local yy = y
  if m <= 2 then yy = yy - 1 end
  local era = (yy >= 0 and yy or yy - 399) // 400
  local yoe = yy - era * 400
  local mp = (m + 9) % 12
  local doy = (153 * mp + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

--- A decimal field of a timestamp as an integer.
--- @param s string Digits, as a pattern capture
--- @return integer The value, 0 when it is not one
local function num(s: string): integer
  return math.tointeger(tonumber(s) or 0) or 0
end

--- Epoch seconds for an ISO 8601 timestamp, computed arithmetically:
--- the date by day count, the zone offset subtracted. `os.time` with a
--- table would read the host's timezone and DST rules instead, and
--- answer differently on two machines for the same commit.
--- @param at string An ISO 8601 timestamp, "Z" or ±HH:MM offset
--- @return integer | nil Seconds since the epoch, UTC
--- @return string Error message
local function epoch(at: string): integer | nil, string
  local y, mo, d, h, mi, s = at:match(
    "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if y == nil then
    return nil, ("not an ISO 8601 timestamp: %s"):format(at)
  end
  local days = days_from_civil(num(y), num(mo), num(d))
  local secs = days * 86400 + num(h) * 3600 + num(mi) * 60 + num(s)
  local sign, oh, om = at:match("([+%-])(%d%d):?(%d%d)$")
  if sign ~= nil then
    local off = num(oh) * 3600 + num(om) * 60
    if sign == "-" then off = -off end
    secs = secs - off
  end
  return secs
end

--- The transition one commit records, or nil when its subject is not
--- one of the three transition shapes. `spec`, `attach`, `block`,
--- `new`, `set` and squash-merge PR titles all land here as nil: each
--- pattern is anchored and describes the whole shape, so a subject
--- merely opening with a verb word matches none. The `verdict` shape
--- stops at its phase pair, not the subject's end, because a verdict
--- may name the session that judged it.
--- @param e store.Event One commit
--- @return Transition | nil The transition it records
local function transition_of(e: store.Event): Transition
  local id, from, to = e.subject:match("^move (%S+) (%S+) %-> (%S+)$")
  if id ~= nil then
    return {id = id, at = e.at, from = from, to = to, verdict = ""}
  end
  local vid, kind, vfrom, vto = e.subject:match(
    "^verdict (%S+) (.-) %((%S+) %-> (%S+)%)")
  if vid ~= nil then
    return {id = vid, at = e.at, from = vfrom, to = vto, verdict = kind}
  end
  local did, reason, dfrom = e.subject:match("^done (%S+) (%S+) %(from (%S+)%)$")
  if did ~= nil then
    return {id = did, at = e.at, from = dfrom, to = "", verdict = reason}
  end
  return nil
end

--- Every transition the log records, in the order the events arrive.
--- @param events {store.Event} The branch log, newest first
--- @return {Transition} The transitions, commits carrying none dropped
local function parse(events: {store.Event}): {Transition}
  local out: {Transition} = {}
  for _, e in ipairs(events) do
    local t = transition_of(e)
    if t ~= nil then out[#out + 1] = t end
  end
  return out
end

--- The value at `q` of a sorted sample by nearest rank: the smallest
--- observation at or above that fraction of the sample.
--- @param sorted {integer} The sample, ascending
--- @param q number The fraction, 0-1
--- @return integer The observation, 0 for an empty sample
local function rank_at(sorted: {integer}, q: number): integer
  if #sorted == 0 then return 0 end
  local idx = math.tointeger(math.ceil(q * #sorted)) or 1
  if idx < 1 then idx = 1 end
  if idx > #sorted then idx = #sorted end
  return sorted[idx]
end

--- Each item's transitions oldest first. Commit times have one-second
--- resolution and two board commits can share one, so a tie falls back
--- to arrival order reversed: `store.history` yields the log newest
--- first, so a later arrival is an earlier commit.
--- @param ts {Transition} The transitions
--- @return {string: {Timed}} Ordered transitions by item id
--- @return {string} The item ids, first-seen order
local function by_item(ts: {Transition}): {string: {Timed}}, {string}
  local groups: {string: {Timed}} = {}
  local order: {string} = {}
  for i, t in ipairs(ts) do
    local at_s = epoch(t.at)
    if at_s ~= nil then
      if groups[t.id] == nil then
        groups[t.id] = {}
        order[#order + 1] = t.id
      end
      local g = groups[t.id]
      g[#g + 1] = {t = t, at_s = at_s, idx = i}
    end
  end
  for _, id in ipairs(order) do
    table.sort(groups[id], function(a: Timed, b: Timed): boolean
        if a.at_s ~= b.at_s then return a.at_s < b.at_s end
        return a.idx > b.idx
      end)
  end
  return groups, order
end

--- Phase dwell over every item: the seconds between entering a phase
--- and the next transition off it. An item's last transition
--- contributes nothing — it is either still in that phase, so its
--- dwell has not ended, or the `done` that ended the item.
--- @param ts {Transition} The transitions
--- @return {string: Dwell} Dwell by phase, phases never left absent
local function dwell(ts: {Transition}): {string: Dwell}
  local groups, order = by_item(ts)
  local samples: {string: {integer}} = {}
  for _, id in ipairs(order) do
    local g = groups[id]
    for i = 1, #g - 1 do
      local phase = g[i].t.to
      local secs = g[i + 1].at_s - g[i].at_s
      if phase ~= "" and secs >= 0 then
        local list = samples[phase] or {}
        list[#list + 1] = secs
        samples[phase] = list
      end
    end
  end
  local out: {string: Dwell} = {}
  for phase, list in pairs(samples) do
    table.sort(list)
    out[phase] = {phase = phase, entries = #list,
      median_s = rank_at(list, 0.5), p90_s = rank_at(list, 0.9)}
  end
  return out
end

--- How often each judged outcome happened, and how much work was
--- pulled. A pull is any `ready -> do`, the one transition a session
--- makes when it takes work, so it is the denominator the verdicts
--- are read against.
--- @param ts {Transition} The transitions
--- @return {string: integer} Counts by outcome, zero when never seen
local function counts(ts: {Transition}): {string: integer}
  local out: {string: integer} = {["accept"] = 0, ["request changes"] = 0,
    ["reject"] = 0, ["completed"] = 0, ["pulls"] = 0}
  for _, t in ipairs(ts) do
    if t.verdict ~= "" and out[t.verdict] ~= nil then
      out[t.verdict] = out[t.verdict] + 1
    end
    if t.from == "ready" and t.to == "do" then out["pulls"] = out["pulls"] + 1 end
  end
  return out
end

--- A duration in the coarsest pair of units that keeps it legible.
--- @param secs integer Seconds
--- @return string The rendering
local function duration(secs: integer): string
  if secs < 60 then return ("%ds"):format(secs) end
  if secs < 3600 then return ("%dm"):format(secs // 60) end
  if secs < 86400 then
    return ("%dh%dm"):format(secs // 3600, (secs % 3600) // 60)
  end
  return ("%dd%dh"):format(secs // 86400, (secs % 86400) // 3600)
end

--- One dwell line per phase in board order, then one counts line. A
--- phase with no ended dwell still prints: that is a fact about the
--- flow, not a line to omit.
--- @param ts {Transition} The transitions
--- @return {string} The lines to print
--- @return string The verdict detail
local function report(ts: {Transition}): {string}, string
  local d = dwell(ts)
  local out: {string} = {}
  for _, phase in ipairs(item.PHASES) do
    local w = d[phase]
    if w == nil then
      out[#out + 1] = ("%-6s dwell n=0"):format(phase)
    else
      out[#out + 1] = ("%-6s dwell n=%d median %s p90 %s"):format(phase,
        w.entries, duration(w.median_s), duration(w.p90_s))
    end
  end
  local c = counts(ts)
  out[#out + 1] = ("counts accept=%d request-changes=%d reject=%d "
    .. "completed=%d pulls=%d"):format(c["accept"], c["request changes"],
    c["reject"], c["completed"], c["pulls"])
  local seen: {string: boolean} = {}
  for _, t in ipairs(ts) do seen[t.id] = true end
  local items = 0
  for _ in pairs(seen) do items = items + 1 end
  return out, ("%d transition(s) across %d item(s)"):format(#ts, items)
end

--- Read the whole branch log and print what it says about the flow.
--- @param s store.Store The store
--- @return integer Exit code
local function cmd_stats(s: store.Store): integer
  local events, err = store.history(s)
  if events == nil then
    return verdict_line("stats", false, err)
  end
  local lines, verdict = report(parse(events))
  for _, line in ipairs(lines) do print(line) end
  return verdict_line("stats", true, verdict)
end

local record flowstat
  type Transition = Transition
  type Dwell = Dwell
  parse: function(events: {store.Event}): {Transition}
  dwell: function(ts: {Transition}): {string: Dwell}
  counts: function(ts: {Transition}): {string: integer}
  report: function(ts: {Transition}): {string}, string
  cmd_stats: function(s: store.Store): integer
end

local M: flowstat = {
  parse = parse,
  dwell = dwell,
  counts = counts,
  report = report,
  cmd_stats = cmd_stats,
}

return M
