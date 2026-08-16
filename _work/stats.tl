--- Flow-review stats over the board's own history. The pure core
--- (stints, summarize) reconstructs per-issue phase stints from
--- issue-timeline events and reports per-phase dwell, occupancy, and
--- backward-motion numbers; cmd_stats is the effect half that fetches
--- the window's issues and their events and prints the report. This
--- tool measures — it does not recommend; the planner reads the
--- numbers and judges (skills/work/review.md's flow-review section).

local time = require("cosmic.time")
local str = require("cosmic.string")
local gh = require("_work.github")
local model = require("_work.model")

--- One issue-timeline event, reduced to what the flow reader needs: a
--- label applied/removed or the issue closing. `column` is the phase a
--- "labeled"/"unlabeled" event's label names, or "" when the event
--- carries no label or one that names no phase. `created_at` stays an
--- ISO 8601 STRING here — stints() is where it becomes an epoch
--- second, via the small pure helper below.
local record LabeledEvent
  issue: integer
  kind: string -- "labeled" | "unlabeled" | "closed" (others are dropped)
  column: string
  created_at: string
end

--- One continuous span an issue spent in one phase: when it began,
--- when (if ever) it ended, and how. `finish` is nil while the span is
--- still running as of the report (an "open" stint).
local record Stint
  issue: integer
  column: string
  start: integer
  finish: integer -- nil when still open at report time
  ended: string -- "moved" | "closed" | "open"
end

--- Per-phase numbers for one report window.
local record ColumnFlow
  column: string
  stint_count: integer
  median_dwell_min: number
  max_dwell_min: number
  peak_occupancy: integer
  at_limit_min: number
end

--- The verdicts and send-backs in the window, counted apart because
--- they mean opposite things: an accept (`check→land`) is work moving
--- on, a rework (`check→do`) is work sent back for changes, and a
--- bounce (`*→plan`) is work sent back to be reshaped.
local record BackwardMoves
  bounces: integer
  accepts: integer
  reworks: integer
end

--- ready→do pickup latency: how long a ready issue waited before an
--- implementer claimed it, over every such transition in the window.
local record PickupLatency
  count: integer
  median_min: number
  max_min: number
end

--- The measured flow for one report window.
local record FlowReport
  columns: {ColumnFlow}
  backward: BackwardMoves
  pickup: PickupLatency
end

--- Epoch seconds for an ISO 8601 timestamp, tolerant of a trailing
--- `\r` (a CRLF-flavored timestamp passed through as-is by a JSON
--- decoder). No os.date: the underlying conversion is cosmic.time's
--- pure civil-days arithmetic (parse_iso8601), so this stays pure and
--- independent of the host's C library or locale.
--- @param created_at string ISO 8601 timestamp
--- @return integer | nil Epoch seconds, or nil if unparseable
local function epoch_of(created_at: string): integer | nil
  local epoch = time.parse_iso8601(str.trim(created_at))
  return epoch
end

--- Reduce one issue's raw timeline events to LabeledEvents: only
--- "labeled"/"unlabeled"/"closed" survive, and a label event's phase
--- is resolved through model.column_of — which reads both the current
--- `work:<phase>` labels and the older `plan:<column>` ones recorded
--- in past events — so a label naming no phase (e.g. "perf") reads as
--- "" rather than crashing the reconstruction.
--- @param issue integer The issue the events belong to
--- @param raw {gh.RawEvent} Raw timeline events, oldest first
--- @return {LabeledEvent} Normalized events, oldest first
local function to_labeled_events(issue: integer, raw: {gh.RawEvent}): {LabeledEvent}
  local out: {LabeledEvent} = {}
  for _, e in ipairs(raw) do
    if e.event == "labeled" or e.event == "unlabeled" or e.event == "closed" then
      local column = ""
      if e.label then
        column = model.column_of({e.label.name}) or ""
      end
      out[#out + 1] = {
        issue = issue,
        kind = e.event,
        column = column,
        created_at = e.created_at,
      }
    end
  end
  return out
end

--- Reconstruct one issue's stints from its own events, oldest first.
--- A "labeled" event for a new phase closes the running stint
--- ("moved") and opens the new one; "unlabeled" for the running
--- phase's own label closes it ("moved") with no replacement yet
--- open; "closed" closes the running stint ("closed"); an event whose
--- timestamp does not parse is skipped rather than corrupting the
--- reconstruction with a bogus instant. A stint still running when the
--- events run out is emitted "open" with a nil finish.
--- @param issue integer The issue the events belong to
--- @param events {LabeledEvent} That issue's events, oldest first
--- @return {Stint} That issue's stints, oldest first
local function stints_for_issue(issue: integer, events: {LabeledEvent}): {Stint}
  local out: {Stint} = {}
  local col: string = nil
  local start: integer = nil
  for _, e in ipairs(events) do
    local at = epoch_of(e.created_at)
    if at ~= nil then
      if e.kind == "labeled" and e.column ~= "" then
        if col ~= nil and col ~= e.column then
          out[#out + 1] = {issue = issue, column = col, start = start,
            finish = at, ended = "moved"}
          col = e.column
          start = at
        elseif col == nil then
          col = e.column
          start = at
        end
      elseif e.kind == "unlabeled" and e.column ~= "" and col == e.column then
        out[#out + 1] = {issue = issue, column = col, start = start,
          finish = at, ended = "moved"}
        col = nil
        start = nil
      elseif e.kind == "closed" and col ~= nil then
        out[#out + 1] = {issue = issue, column = col, start = start,
          finish = at, ended = "closed"}
        col = nil
        start = nil
      end
    end
  end
  if col ~= nil then
    out[#out + 1] = {issue = issue, column = col, start = start,
      finish = nil, ended = "open"}
  end
  return out
end

--- Reconstruct every issue's phase stints from its labeled/unlabeled/
--- closed events. Events for several issues may be mixed in one list
--- — this groups by `issue` first, so cmd_stats can hand it one big
--- concatenated list straight off its per-issue fetch loop.
--- @param events {LabeledEvent} Normalized events, any issue order
--- @return {Stint} Every stint, grouped by issue, each issue's oldest first
local function stints(events: {LabeledEvent}): {Stint}
  local by_issue: {integer: {LabeledEvent}} = {}
  local order: {integer} = {}
  for _, e in ipairs(events) do
    local list = by_issue[e.issue]
    if list == nil then
      list = {}
      by_issue[e.issue] = list
      order[#order + 1] = e.issue
    end
    list[#list + 1] = e
  end
  local out: {Stint} = {}
  for _, issue in ipairs(order) do
    for _, s in ipairs(stints_for_issue(issue, by_issue[issue])) do
      out[#out + 1] = s
    end
  end
  return out
end

--- A sorted copy of a value list, ascending. Pure, small: this module
--- stays self-contained rather than reaching into _perf/stats.tl for
--- median/max, a different subsystem's helper.
--- @param values {number} The values
--- @return {number} A new, ascending-sorted list
local function sorted_copy(values: {number}): {number}
  local copy: {number} = {}
  for i, v in ipairs(values) do
    copy[i] = v
  end
  table.sort(copy)
  return copy
end

--- Median of a value list (midpoint of the two middle values for even
--- counts); 0 for an empty list.
--- @param values {number} The values
--- @return number The median
local function median(values: {number}): number
  local n = #values
  if n == 0 then
    return 0
  end
  local s = sorted_copy(values)
  local mid = n // 2
  if n % 2 == 1 then
    return s[mid + 1]
  end
  return (s[mid] + s[mid + 1]) / 2
end

--- Largest value in a list; 0 for an empty list.
--- @param values {number} The values
--- @return number The maximum
local function max_of(values: {number}): number
  if #values == 0 then
    return 0
  end
  local m = values[1]
  for _, v in ipairs(values) do
    if v > m then
      m = v
    end
  end
  return m
end

--- One start (+1) or finish (-1) instant in the occupancy sweep.
local record Delta
  at: integer
  d: integer
end

--- Peak concurrent stints in one phase's list, and the total minutes
--- spent at or over `limit` concurrent stints — a sweep over
--- start/finish instants. At a shared instant an ending stint is
--- processed before a starting one, so a stint's exact-instant
--- hand-off to another (one's finish equals the next's start) never
--- registers as a transient extra peak.
--- @param list {Stint} Stints in one phase
--- @param now_epoch integer "Now", substituted for an open stint's finish
--- @param limit integer The phase's WIP limit
--- @return integer Peak concurrent stints
--- @return number Minutes spent at or over the limit
local function occupancy(list: {Stint}, now_epoch: integer,
    limit: integer): integer, number
  if #list == 0 then
    return 0, 0
  end
  local deltas: {Delta} = {}
  for _, s in ipairs(list) do
    local fin = s.finish or now_epoch
    deltas[#deltas + 1] = {at = s.start, d = 1}
    deltas[#deltas + 1] = {at = fin, d = -1}
  end
  table.sort(deltas, function(a: Delta, b: Delta): boolean
      if a.at ~= b.at then
        return a.at < b.at
      end
      return a.d < b.d
    end)
  local cur = 0
  local peak = 0
  local at_limit_secs = 0
  local prev_at: integer = nil
  for _, ev in ipairs(deltas) do
    if prev_at ~= nil and cur >= limit then
      at_limit_secs = at_limit_secs + (ev.at - prev_at)
    end
    cur = cur + ev.d
    if cur > peak then
      peak = cur
    end
    prev_at = ev.at
  end
  return peak, at_limit_secs / 60.0
end

--- Summarize a set of stints into a FlowReport: per phase, stint
--- count, median/max dwell minutes, peak occupancy, and minutes at or
--- over the phase's WIP limit (model.LIMITS); across all phases, the
--- bounces, accepts and reworks, and ready→do pickup latencies. An
--- open stint's dwell and occupancy run to `now_iso`.
--- @param all_stints {Stint} Stints from any number of issues
--- @param now_iso string ISO 8601 "now", for open stints
--- @return FlowReport The measured flow
local function summarize(all_stints: {Stint}, now_iso: string): FlowReport
  local now_epoch = epoch_of(now_iso) or 0
  local by_column: {string: {Stint}} = {}
  for _, col in ipairs(model.COLUMNS) do
    by_column[col] = {}
  end
  for _, s in ipairs(all_stints) do
    local list = by_column[s.column]
    if list then
      list[#list + 1] = s
    end
  end
  local columns: {ColumnFlow} = {}
  for _, col in ipairs(model.COLUMNS) do
    local list = by_column[col]
    local dwell: {number} = {}
    for _, s in ipairs(list) do
      local fin = s.finish or now_epoch
      dwell[#dwell + 1] = (fin - s.start) / 60.0
    end
    local peak, at_limit_min = occupancy(list, now_epoch, model.LIMITS[col])
    columns[#columns + 1] = {
      column = col,
      stint_count = #list,
      median_dwell_min = median(dwell),
      max_dwell_min = max_of(dwell),
      peak_occupancy = peak,
      at_limit_min = at_limit_min,
    }
  end
  local by_issue: {integer: {Stint}} = {}
  local order: {integer} = {}
  for _, s in ipairs(all_stints) do
    local list = by_issue[s.issue]
    if list == nil then
      list = {}
      by_issue[s.issue] = list
      order[#order + 1] = s.issue
    end
    list[#list + 1] = s
  end
  local bounces = 0
  local accepts = 0
  local reworks = 0
  local pickup: {number} = {}
  for _, issue in ipairs(order) do
    local list = by_issue[issue]
    table.sort(list, function(a: Stint, b: Stint): boolean
        return a.start < b.start
      end)
    for i = 1, #list - 1 do
      local cur = list[i]
      local nxt = list[i + 1]
      if cur.ended == "moved" then
        if nxt.column == "plan" then
          bounces = bounces + 1
        elseif cur.column == "check" and nxt.column == "land" then
          accepts = accepts + 1
        elseif cur.column == "check" and nxt.column == "do" then
          reworks = reworks + 1
        end
        if cur.column == "ready" and nxt.column == "do" then
          pickup[#pickup + 1] = (cur.finish - cur.start) / 60.0
        end
      end
    end
  end
  return {
    columns = columns,
    backward = {bounces = bounces, accepts = accepts, reworks = reworks},
    pickup = {count = #pickup, median_min = median(pickup), max_min = max_of(pickup)},
  }
end

--- stats: fetch every work-labeled issue updated in the last `days`
--- days (open and closed), replay each one's timeline events through
--- the pure core, and print the measured flow. `days` counts back from
--- "now"; an issue with no events in that window (e.g. one that never
--- moved) contributes nothing.
--- @param repo string "owner/name"
--- @param days integer Report window, in days back from now
--- @return integer Exit code
local function cmd_stats(repo: string, days: integer): integer
  local now_epoch = time.now()
  local now_iso = time.format_iso8601(now_epoch)
  local since_iso = time.format_iso8601(now_epoch - days * 86400)
  local numbers: {integer: boolean} = {}
  local issues: {integer} = {}
  for _, col in ipairs(model.COLUMNS) do
    local raw, err = gh.list_issues(repo, "work:" .. col,
      {state = "all", since = since_iso})
    if raw == nil then
      io.stderr:write(("listing %s: %s"):format(col, err) .. "\n")
      print("work-stats: ERROR")
      return 1
    end
    for _, i in ipairs(raw) do
      if not numbers[i.number] then
        numbers[i.number] = true
        issues[#issues + 1] = i.number
      end
    end
  end
  local events: {LabeledEvent} = {}
  for _, n in ipairs(issues) do
    local raw, err = gh.list_issue_events(repo, n)
    if raw == nil then
      io.stderr:write(("events #%d: %s"):format(n, err) .. "\n")
      print("work-stats: ERROR")
      return 1
    end
    for _, e in ipairs(to_labeled_events(n, raw)) do
      events[#events + 1] = e
    end
  end
  local report = summarize(stints(events), now_iso)
  print(("work flow — %s, last %d day(s), %d issue(s)"):format(
      repo, days, #issues))
  print(("%-8s %6s %12s %11s %6s %13s"):format(
      "phase", "stints", "med dwell", "max dwell", "peak", "min at-limit"))
  for _, c in ipairs(report.columns) do
    print(("%-8s %6d %12.1f %11.1f %6d %13.1f"):format(
        c.column, c.stint_count, c.median_dwell_min, c.max_dwell_min,
        c.peak_occupancy, c.at_limit_min))
  end
  print(("verdicts: %d accept(s) (check->land), %d rework(s) (check->do), "
      .. "%d bounce(s) (*->plan)"):format(
      report.backward.accepts, report.backward.reworks, report.backward.bounces))
  print(("ready->do pickup latency: %d transition(s), median %.1f min, "
      .. "max %.1f min"):format(
      report.pickup.count, report.pickup.median_min, report.pickup.max_min))
  print("work-stats: OK")
  return 0
end

local record stats
  type LabeledEvent = LabeledEvent
  type Stint = Stint
  type ColumnFlow = ColumnFlow
  type BackwardMoves = BackwardMoves
  type PickupLatency = PickupLatency
  type FlowReport = FlowReport
  to_labeled_events: function(issue: integer, raw: {gh.RawEvent}): {LabeledEvent}
  stints: function(events: {LabeledEvent}): {Stint}
  summarize: function(all_stints: {Stint}, now_iso: string): FlowReport
  cmd_stats: function(repo: string, days: integer): integer
end

local M: stats = {
  to_labeled_events = to_labeled_events,
  stints = stints,
  summarize = summarize,
  cmd_stats = cmd_stats,
}

return M
