#!/usr/bin/env cosmic
--- The G8 flow reader: lead time, rework rate, and bounce counts,
--- derived from the board's own git log rather than a field any item
--- carries. Two halves:
---
---   PURE  `events_of` parses `%ct %s`-formatted log lines into typed
---         events; `stats_of` derives per-item and board-wide numbers
---         from them. Neither touches git or the filesystem, so both
---         are tested over synthetic lines and synthetic events.
---   IO    `main` shells to `git log` once, and prints the result as
---         one `key=value` line per completed item plus a summary
---         line, in the grammar `cosmic.instrument`/`cosmic.log`
---         share, so a downstream reader parses it with the standing
---         tools rather than a new format.
---
--- Every event kind here is a fixed grammar `_work.gitverbs` and
--- `_work.gitverdict` already write to the log; a subject this file
--- does not recognize (`new`, `spec`, `compare`, a plain commit
--- message, ...) is skipped rather than guessed at.
---
---   bin/cosmic _work/flowstats.tl [--dir D] [--since EPOCH]
local child = require("cosmic.child")
local flags = require("cosmic.flags")
local proc = require("cosmic.proc")

--- One parsed board-log event. Every field is present on every event;
--- a field a kind does not use carries its zero value ("", 0, false)
--- rather than nil, the same convention `_work.item.Item` uses for a
--- fact that does not apply yet.
local record Event
  --- "take" | "drop" | "verdict" | "done" | "review".
  kind: string
  --- Commit time, seconds since the epoch (git's `%ct`).
  ts: integer
  --- The item's 8-character id prefix, as the log renders it.
  id: string
  --- take: the PR handed over in the same take; 0 when none.
  pr: integer
  --- drop: released the review claim rather than the item; a bounce
  --- is a drop with this false.
  review_drop: boolean
  --- verdict: "accept" | "request changes". Any other kind (a
  --- "reject", or an older log grammar this file does not parse) is
  --- an event `events_of` does not emit at all.
  verdict_kind: string
  --- done: "completed" | "not-planned".
  reason: string
end

--- One completed item's numbers.
local record ItemStats
  --- The item's 8-character id prefix.
  id: string
  --- First take to the completed done, in seconds.
  lead_s: integer
  --- Verdicts written against the item — every round, accept or
  --- request-changes alike.
  rounds: integer
  --- Non-review drops: the item bounced back to todo, the gap named.
  bounces: integer
end

--- Board-wide numbers over every completed item the log carries. An
--- item still in flight, or one that ended `not-planned`, contributes
--- to nothing here — there is no lead time to measure and no rounds
--- to close.
local record Stats
  --- One entry per completed item, in the order `events_of` saw its
  --- done event.
  items: {ItemStats}
  --- Median lead_s across `items`.
  lead_p50_s: integer
  --- 90th-percentile lead_s across `items`.
  lead_p90_s: integer
  --- Request-changes verdicts across `items` — the rework rate's
  --- numerator.
  rework_accepts: integer
  --- All verdicts across `items` — the rework rate's denominator.
  rework_total: integer
  --- Non-review drops across `items`, summed.
  bounces: integer
end

--- An event with every field at its zero value except the three every
--- kind carries.
local function bare(kind: string, ts: integer, id: string): Event
  return {kind = kind, ts = ts, id = id, pr = 0, review_drop = false,
    verdict_kind = "", reason = ""}
end

--- A `take ID by SESSION[ pr:N][ (taken over from ...)][ (forced: ...)]`
--- line, or nil.
local function try_take(ts: integer, rest: string): Event | nil
  local id, after = rest:match("^take (%S+) by%s*(.*)$")
  if id == nil then
    return nil
  end
  local ev = bare("take", ts, id)
  local prnum = after:match("pr:(%d+)")
  if prnum ~= nil then
    ev.pr = math.tointeger(tonumber(prnum)) or 0
  end
  return ev
end

--- A `drop ID: WHY` (a bounce) or `drop ID review: WHY` (releases only
--- the review claim) line, or nil.
local function try_drop(ts: integer, rest: string): Event | nil
  local id = rest:match("^drop (%S+) review:")
  if id ~= nil then
    local ev = bare("drop", ts, id)
    ev.review_drop = true
    return ev
  end
  id = rest:match("^drop (%S+):")
  if id ~= nil then
    return bare("drop", ts, id)
  end
  return nil
end

--- A `verdict ID accept...` or `verdict ID request changes...` line,
--- or nil for any other kind (a reject, or an older log's grammar).
local function try_verdict(ts: integer, rest: string): Event | nil
  local id, after = rest:match("^verdict (%S+) (.*)$")
  if id == nil then
    return nil
  end
  local kind = ""
  if after:match("^request changes") then
    kind = "request changes"
  elseif after:match("^accept") then
    kind = "accept"
  end
  if kind == "" then
    return nil
  end
  local ev = bare("verdict", ts, id)
  ev.verdict_kind = kind
  return ev
end

--- A `done ID REASON (from FROM)...` line, or nil when REASON is
--- neither "completed" nor "not-planned".
local function try_done(ts: integer, rest: string): Event | nil
  local id, reason = rest:match("^done (%S+) (%S+) %(from")
  if id == nil then
    return nil
  end
  if reason ~= "completed" and reason ~= "not-planned" then
    return nil
  end
  local ev = bare("done", ts, id)
  ev.reason = reason
  return ev
end

--- A `review ID claimed by SESSION...` line, or nil.
local function try_review(ts: integer, rest: string): Event | nil
  local id = rest:match("^review (%S+) claimed")
  if id == nil then
    return nil
  end
  return bare("review", ts, id)
end

--- Parses `%ct %s`-formatted board-log lines into events, skipping
--- any line whose subject is not one of the five fixed grammars above
--- (an unparseable timestamp skips the line too).
--- @param lines {string} One git-log line per entry, oldest or newest first — order does not matter
--- @return {Event} The events, in the same order as `lines`
local function events_of(lines: {string}): {Event}
  local out: {Event} = {}
  for _, line in ipairs(lines) do
    local ts_str, rest = line:match("^(%d+)%s+(.*)$")
    if ts_str ~= nil then
      local ts = math.tointeger(tonumber(ts_str))
      if ts ~= nil then
        local ev = try_take(ts, rest) or try_drop(ts, rest)
        or try_verdict(ts, rest) or try_done(ts, rest) or try_review(ts, rest)
        if ev ~= nil then
          out[#out + 1] = ev
        end
      end
    end
  end
  return out
end

--- Per-id running totals, kept only long enough to fold into `Stats`.
local record Acc
  first_take: integer
  took: boolean
  done_ts: integer
  completed: boolean
  verdicts: integer
  rework: integer
  drops: integer
end

--- The rank-`p` value of a sorted-ascending list, nearest-rank (no
--- interpolation): `p=50` is the median, `p=90` the 90th percentile.
--- @param sorted {integer} Ascending values
--- @param p number A percentage in (0, 100]
--- @return integer The value at that rank, or 0 for an empty list
local function percentile(sorted: {integer}, p: number): integer
  if #sorted == 0 then
    return 0
  end
  local idx = math.ceil(p / 100 * #sorted)
  if idx < 1 then
    idx = 1
  end
  if idx > #sorted then
    idx = #sorted
  end
  return sorted[idx]
end

--- The id's running totals, creating them (and recording first-seen
--- order) on the first event that names it.
local function get_acc(by_id: {string: Acc}, order: {string}, id: string): Acc
  local a = by_id[id]
  if a ~= nil then
    return a
  end
  local fresh: Acc = {first_take = 0, took = false, done_ts = 0,
    completed = false, verdicts = 0, rework = 0, drops = 0}
  by_id[id] = fresh
  order[#order + 1] = id
  return fresh
end

--- Derives per-item and board-wide flow numbers from a parsed event
--- list. An item with no completed done contributes nothing: not to
--- `items`, not to the summary — the point of lead time is measuring
--- the whole span an item was open, so a still-open item has none yet
--- to report.
--- @param events {Event} Events in any order — grouped and folded by id
--- @return Stats The derived numbers
local function stats_of(events: {Event}): Stats
  local by_id: {string: Acc} = {}
  local order: {string} = {}
  for _, e in ipairs(events) do
    local a = get_acc(by_id, order, e.id)
    if e.kind == "take" then
      if not a.took or e.ts < a.first_take then
        a.first_take = e.ts
        a.took = true
      end
    elseif e.kind == "drop" and not e.review_drop then
      a.drops = a.drops + 1
    elseif e.kind == "verdict" then
      a.verdicts = a.verdicts + 1
      if e.verdict_kind == "request changes" then
        a.rework = a.rework + 1
      end
    elseif e.kind == "done" and e.reason == "completed" then
      a.completed = true
      a.done_ts = e.ts
    end
  end

  local items: {ItemStats} = {}
  local leads: {integer} = {}
  local rework_accepts = 0
  local rework_total = 0
  local bounces = 0
  for _, id in ipairs(order) do
    local a = by_id[id]
    if a ~= nil and a.completed and a.took then
      local lead = a.done_ts - a.first_take
      if lead < 0 then
        lead = 0
      end
      items[#items + 1] = {id = id, lead_s = lead, rounds = a.verdicts,
        bounces = a.drops}
      leads[#leads + 1] = lead
      rework_accepts = rework_accepts + a.rework
      rework_total = rework_total + a.verdicts
      bounces = bounces + a.drops
    end
  end
  table.sort(leads)

  return {
    items = items,
    lead_p50_s = percentile(leads, 50),
    lead_p90_s = percentile(leads, 90),
    rework_accepts = rework_accepts,
    rework_total = rework_total,
    bounces = bounces,
  }
end

local SPEC: flags.Spec = {
  name = "flowstats",
  summary = "lead time, rework rate, and bounce counts from the board's git log",
  flags = {
    {long = "dir", arg = "DIR", default = ".", help = "the board checkout to read"},
    {long = "since", arg = "EPOCH",
      help = "only commits at or after this unix timestamp"},
  },
}

--- CLI entry point: reads the board's log with one `git log` call,
--- and prints the derived numbers.
--- @param ... string Command-line arguments
--- @return integer Exit code
local function main(...: string): integer
  local parsed, perr = flags.parse(SPEC, {...})
  if parsed == nil then
    io.stderr:write("flowstats: " .. tostring(perr) .. "\n")
    return 1
  end
  if parsed.help then
    print(flags.help(SPEC))
    return 0
  end
  local dir = parsed.values["dir"] or "."
  local since = parsed.values["since"] or ""
  local argv: {string} = {"git", "log", "--format=%ct %s"}
  if since ~= "" then
    argv[#argv + 1] = "--since=@" .. since
  end
  local r, rerr = child.run(argv, {cwd = dir})
  if r == nil then
    io.stderr:write("flowstats: " .. tostring(rerr) .. "\n")
    return 1
  end
  if not r.ok then
    io.stderr:write("flowstats: git log failed: "
      .. ((r.stderr or ""):gsub("%s+$", "")) .. "\n")
    return 1
  end
  local lines: {string} = {}
  for line in (r.stdout or ""):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  local stats = stats_of(events_of(lines))
  for _, it in ipairs(stats.items) do
    print(("flow item=%s lead_s=%d rounds=%d bounces=%d"):format(
        it.id, it.lead_s, it.rounds, it.bounces))
  end
  print(("flow summary items=%d lead_p50_s=%d lead_p90_s=%d rework=%d/%d bounces=%d")
    :format(#stats.items, stats.lead_p50_s, stats.lead_p90_s,
      stats.rework_accepts, stats.rework_total, stats.bounces))
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end

local record flowstats
  type Event = Event
  type ItemStats = ItemStats
  type Stats = Stats
  events_of: function(lines: {string}): {Event}
  stats_of: function(events: {Event}): Stats
  main: function(...: string): integer
end

local M: flowstats = {
  events_of = events_of,
  stats_of = stats_of,
  main = main,
}

return M
