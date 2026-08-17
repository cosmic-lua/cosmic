#!/usr/bin/env cosmic
--- Pure-core tests for _work/stats.tl: stints() and summarize() over
--- hand-built LabeledEvent fixtures. No network — RawEvent/gh never
--- appear here.
local stats = require("_work.stats")
local model = require("_work.model")

local type LabeledEvent = stats.LabeledEvent

--- A minute-precision dwell in seconds, for hand-checking a stint's
--- (finish - start) against a known interval without re-parsing dates.
local function secs(minutes: integer): integer
  return minutes * 60
end

local function test_stints_normal_flow_and_ready_pickup()
  local events: {LabeledEvent} = {
    {issue = 101, kind = "labeled", phase = "plan",
      created_at = "2026-08-01T00:00:00Z"},
    {issue = 101, kind = "labeled", phase = "ready",
      created_at = "2026-08-01T02:00:00Z"},
    {issue = 101, kind = "labeled", phase = "do",
      created_at = "2026-08-01T02:30:00Z"},
    {issue = 101, kind = "labeled", phase = "check",
      created_at = "2026-08-01T04:30:00Z"},
    {issue = 101, kind = "labeled", phase = "land",
      created_at = "2026-08-01T05:00:00Z"},
    {issue = 101, kind = "closed", phase = "",
      created_at = "2026-08-01T05:30:00Z"},
  }
  local s = stats.stints(events)
  assert(#s == 5, "expected 5 stints, got " .. tostring(#s))
  local want_phases = {"plan", "ready", "do", "check", "land"}
  local want_dwell_min = {120, 30, 120, 30, 30}
  for i, st in ipairs(s) do
    assert(st.issue == 101, "stint " .. i .. " should carry issue 101")
    assert(st.phase == want_phases[i], ("stint %d: expected phase %s, got %s")
      :format(i, want_phases[i], st.phase))
    assert(st.finish ~= nil, "stint " .. i .. " should have a finish")
    assert(st.finish - st.start == secs(want_dwell_min[i]),
      ("stint %d: expected %d min dwell, got %ds"):format(
        i, want_dwell_min[i], st.finish - st.start))
  end
  assert(s[1].ended == "moved" and s[2].ended == "moved"
    and s[3].ended == "moved", "the first three stints end by a label move")
  assert(s[5].ended == "closed", "the last stint ends by the issue closing")

  local report = stats.summarize(s, "2026-08-01T06:00:00Z")
  assert(report.pickup.count == 1,
    "expected one ready->do pickup, got " .. tostring(report.pickup.count))
  assert(report.pickup.median_min == 30.0,
    "expected 30min pickup latency, got " .. tostring(report.pickup.median_min))
  assert(report.pickup.max_min == 30.0,
    "expected 30min max pickup latency, got " .. tostring(report.pickup.max_min))
  assert(report.backward.accepts == 1,
    "the check->land move is one accept, got "
    .. tostring(report.backward.accepts))
  assert(report.backward.bounces == 0 and report.backward.reworks == 0,
    "a clean forward flow has no bounces and no reworks")
end
test_stints_normal_flow_and_ready_pickup()

local function test_bounce_ready_to_plan()
  local events: {LabeledEvent} = {
    {issue = 102, kind = "labeled", phase = "ready",
      created_at = "2026-08-02T00:00:00Z"},
    {issue = 102, kind = "labeled", phase = "plan",
      created_at = "2026-08-02T00:15:00Z"},
    {issue = 102, kind = "closed", phase = "",
      created_at = "2026-08-02T00:45:00Z"},
  }
  local s = stats.stints(events)
  local report = stats.summarize(s, "2026-08-02T01:00:00Z")
  assert(report.backward.bounces == 1,
    "expected 1 bounce, got " .. tostring(report.backward.bounces))
  assert(report.backward.reworks == 0 and report.backward.accepts == 0,
    "a bounce is neither a rework nor an accept")
end
test_bounce_ready_to_plan()

local function test_rework_check_to_do()
  local events: {LabeledEvent} = {
    {issue = 103, kind = "labeled", phase = "check",
      created_at = "2026-08-03T00:00:00Z"},
    {issue = 103, kind = "labeled", phase = "do",
      created_at = "2026-08-03T00:50:00Z"},
    {issue = 103, kind = "closed", phase = "",
      created_at = "2026-08-03T01:10:00Z"},
  }
  local s = stats.stints(events)
  local report = stats.summarize(s, "2026-08-03T02:00:00Z")
  assert(report.backward.reworks == 1,
    "expected 1 rework, got " .. tostring(report.backward.reworks))
  assert(report.backward.bounces == 0 and report.backward.accepts == 0,
    "a check->do send-back is neither a bounce nor an accept")
end
test_rework_check_to_do()

local function test_accept_check_to_land()
  local events: {LabeledEvent} = {
    {issue = 105, kind = "labeled", phase = "check",
      created_at = "2026-08-06T00:00:00Z"},
    {issue = 105, kind = "labeled", phase = "land",
      created_at = "2026-08-06T00:20:00Z"},
    {issue = 105, kind = "closed", phase = "",
      created_at = "2026-08-06T00:35:00Z"},
  }
  local s = stats.stints(events)
  local report = stats.summarize(s, "2026-08-06T01:00:00Z")
  assert(report.backward.accepts == 1,
    "expected 1 accept, got " .. tostring(report.backward.accepts))
  assert(report.backward.reworks == 0 and report.backward.bounces == 0,
    "an accept is neither a rework nor a bounce")
end
test_accept_check_to_land()

local function test_open_at_now_stint_tolerates_crlf_timestamp()
  -- The trailing \r simulates a CRLF-flavored timestamp passed through
  -- verbatim by a JSON decoder; epoch_of must still parse it.
  local events: {LabeledEvent} = {
    {issue = 104, kind = "labeled", phase = "do",
      created_at = "2026-08-04T00:00:00Z\r"},
  }
  local s = stats.stints(events)
  assert(#s == 1, "expected 1 open stint, got " .. tostring(#s))
  assert(s[1].finish == nil, "an issue with no further events is still open")
  assert(s[1].ended == "open", "expected ended == open, got " .. tostring(s[1].ended))

  -- 90 minutes after the stint started.
  local report = stats.summarize(s, "2026-08-04T01:30:00Z")
  local doing = report.phases[3]
  assert(doing.phase == "do", "phases[3] should be do")
  assert(doing.stint_count == 1, "expected 1 do stint")
  assert(doing.median_dwell_min == 90.0,
    "expected 90min dwell to now, got " .. tostring(doing.median_dwell_min))
  assert(doing.max_dwell_min == 90.0,
    "expected 90min max dwell, got " .. tostring(doing.max_dwell_min))
  assert(doing.peak_occupancy == 1, "a single open stint peaks at 1")
  assert(doing.at_limit_min == 0.0, "1 concurrent stint never reaches do's limit")
end
test_open_at_now_stint_tolerates_crlf_timestamp()

local function test_occupancy_peak_and_at_limit_minutes()
  -- Five issues sit in "do" (WIP limit 5) for the same 10-minute
  -- window: peak occupancy hits the limit for exactly that window.
  local events: {LabeledEvent} = {}
  for n = 201, 205 do
    events[#events + 1] = {issue = n, kind = "labeled", phase = "do",
      created_at = "2026-08-05T00:00:00Z"}
    events[#events + 1] = {issue = n, kind = "closed", phase = "",
      created_at = "2026-08-05T00:10:00Z"}
  end
  local s = stats.stints(events)
  assert(#s == 5, "expected 5 stints, got " .. tostring(#s))
  local report = stats.summarize(s, "2026-08-05T01:00:00Z")
  local doing = report.phases[3]
  assert(doing.phase == "do", "phases[3] should be do")
  assert(doing.stint_count == 5, "expected 5 do stints")
  assert(doing.median_dwell_min == 10.0,
    "expected 10min median dwell, got " .. tostring(doing.median_dwell_min))
  assert(doing.max_dwell_min == 10.0,
    "expected 10min max dwell, got " .. tostring(doing.max_dwell_min))
  assert(doing.peak_occupancy == model.LIMITS["do"],
    ("expected peak occupancy %d, got %d"):format(
      model.LIMITS["do"], doing.peak_occupancy))
  assert(doing.at_limit_min == 10.0,
    "expected 10min at or over the limit, got " .. tostring(doing.at_limit_min))
end
test_occupancy_peak_and_at_limit_minutes()
