#!/usr/bin/env cosmic
-- The pure half of the G8 flow reader: the event grammar `events_of`
-- recognizes, and the per-item/board-wide fold `stats_of` derives from
-- them. `main`'s one `git log` call is the only IO this module has,
-- and it is exercised against a real checkout, not here.

local flowstats = require("_work.flowstats")

local type Event = flowstats.Event

local function test_the_five_grammars_parse()
  local events = flowstats.events_of({
      "1788019810 done 3IVUGuv6 completed (from accepted)",
      "1788019766 verdict 3IVUGuv6 accept by review-3IVUGuv6-1788019588",
      "1788019571 take 3IVUGuv6 by wave-w3-1788018501 pr:1503",
      "1788019409 verdict 3IVUGuv6 request changes by review-3IVUGuv6-1788019157",
      "1788019157 review 3IVUGuv6 claimed by review-3IVUGuv6-1788019157",
    })
  assert(#events == 5, "all five lines carry a recognized subject: got " .. #events)
  assert(events[1].kind == "done" and events[1].ts == 1788019810
    and events[1].id == "3IVUGuv6" and events[1].reason == "completed",
    "done: " .. events[1].kind)
  assert(events[2].kind == "verdict" and events[2].verdict_kind == "accept",
    "verdict accept: " .. events[2].verdict_kind)
  assert(events[3].kind == "take" and events[3].pr == 1503,
    "take with pr: " .. events[3].pr)
  assert(events[4].kind == "verdict"
    and events[4].verdict_kind == "request changes",
    "verdict request changes: " .. events[4].verdict_kind)
  assert(events[5].kind == "review" and events[5].id == "3IVUGuv6",
    "review claim: " .. events[5].kind)
end

-- A subject none of the five grammars own — a `new`, a tooling commit
-- ("gitboard verdict: ..."), or a line with no leading timestamp at
-- all — is skipped rather than guessed at.
local function test_unknown_subjects_are_skipped()
  local events = flowstats.events_of({
      "1788019336 new 3Ib3FO7T deflate the embedded .lua payload",
      "1788019800 gitboard verdict: verify --head before recording it (#1503)",
      "not even a timestamp",
      "1788019810 done 3IVUGuv6 completed (from accepted)",
    })
  assert(#events == 1, "only the recognized line survives: got " .. #events)
  assert(events[1].kind == "done")
end

local function test_take_pr_is_optional()
  local events = flowstats.events_of({"100 take abcd1234 by session-a"})
  assert(#events == 1 and events[1].pr == 0,
    "no pr: token means pr=0: got " .. events[1].pr)
end

local function test_a_reject_verdict_parses()
  local events = flowstats.events_of({"100 verdict abc12345 reject by rev-x"})
  assert(#events == 1 and events[1].kind == "verdict"
    and events[1].verdict_kind == "reject",
    "reject verdict parses: got " .. events[1].verdict_kind)
end

local function test_a_review_drop_parses_with_the_flag_set()
  local events = flowstats.events_of(
    {"100 drop abcd1234 review: looks dead to me"})
  assert(#events == 1 and events[1].kind == "drop"
    and events[1].review_drop == true, "a review-drop is flagged")
end

--- A synthetic event, defaulting every field a kind does not use —
--- the same zero values `events_of` would have set.
local function bare(kind: string, ts: integer, id: string): Event
  return {kind = kind, ts = ts, id = id, pr = 0, review_drop = false,
    verdict_kind = "", reason = ""}
end

local function take(ts: integer, id: string, pr: integer): Event
  local e = bare("take", ts, id)
  e.pr = pr
  return e
end

local function drop(ts: integer, id: string, review_drop: boolean): Event
  local e = bare("drop", ts, id)
  e.review_drop = review_drop
  return e
end

local function verdict(ts: integer, id: string, kind: string): Event
  local e = bare("verdict", ts, id)
  e.verdict_kind = kind
  return e
end

local function done(ts: integer, id: string, reason: string): Event
  local e = bare("done", ts, id)
  e.reason = reason
  return e
end

-- take -> request-changes -> take (with the PR) -> accept -> done: two
-- rounds, no bounce, lead from the FIRST take.
local function test_a_rework_round_then_accept_counts_two_rounds()
  local events: {Event} = {
    take(100, "item0001", 0),
    verdict(110, "item0001", "request changes"),
    take(120, "item0001", 42),
    verdict(130, "item0001", "accept"),
    done(140, "item0001", "completed"),
  }
  local stats = flowstats.stats_of(events)
  assert(#stats.items == 1, "one completed item: got " .. #stats.items)
  local it = stats.items[1]
  assert(it.id == "item0001")
  assert(it.rounds == 2, "two verdicts: got " .. it.rounds)
  assert(it.bounces == 0, "no drops: got " .. it.bounces)
  assert(it.lead_s == 40,
    "lead is the first take (100) to done (140): got " .. it.lead_s)
end

-- take -> reject -> take (a reject clears the claim by the verb itself,
-- no separate drop line) -> accept -> done: two rounds, and the reject
-- counts toward rework just as a request-changes would — 1 of 2.
local function test_a_reject_then_fresh_take_and_accept_counts_two_rounds()
  local events: {Event} = {
    take(100, "item0006", 0),
    verdict(110, "item0006", "reject"),
    take(200, "item0006", 0),
    verdict(210, "item0006", "accept"),
    done(220, "item0006", "completed"),
  }
  local stats = flowstats.stats_of(events)
  assert(#stats.items == 1, "one completed item: got " .. #stats.items)
  local it = stats.items[1]
  assert(it.rounds == 2, "two verdicts: got " .. it.rounds)
  assert(stats.rework_total == 2, "two verdicts total: got " .. stats.rework_total)
  assert(stats.rework_accepts == 1,
    "reject counts as rework, accept doesn't: got " .. stats.rework_accepts)
end

-- take -> drop -> take -> ... -> done: one bounce, and the lead still
-- runs from the FIRST take — time spent back in the queue after a
-- bounce is exactly the span lead time is meant to measure.
local function test_a_bounce_counts_and_lead_stays_from_first_take()
  local events: {Event} = {
    take(100, "item0002", 0),
    drop(110, "item0002", false),
    take(200, "item0002", 0),
    done(250, "item0002", "completed"),
  }
  local stats = flowstats.stats_of(events)
  assert(#stats.items == 1)
  local it = stats.items[1]
  assert(it.bounces == 1, "one non-review drop: got " .. it.bounces)
  assert(it.lead_s == 150,
    "lead from the first take (100), not the retake: got " .. it.lead_s)
end

-- A review-drop releases the review claim, not the item — it is never
-- a bounce.
local function test_a_review_drop_does_not_count_as_a_bounce()
  local events: {Event} = {
    take(100, "item0003", 5),
    drop(110, "item0003", true),
    verdict(120, "item0003", "accept"),
    done(130, "item0003", "completed"),
  }
  local stats = flowstats.stats_of(events)
  assert(#stats.items == 1)
  assert(stats.items[1].bounces == 0, "a review drop is not a bounce: got "
    .. stats.items[1].bounces)
end

-- An item still in flight — no done at all — contributes nothing: not
-- an entry in `items`, not a tick against the board-wide totals.
local function test_an_incomplete_item_contributes_nothing()
  local events: {Event} = {
    take(100, "item0004", 0),
    verdict(110, "item0004", "request changes"),
  }
  local stats = flowstats.stats_of(events)
  assert(#stats.items == 0, "no done event means nothing to report")
  assert(stats.lead_p50_s == 0 and stats.lead_p90_s == 0)
  assert(stats.rework_total == 0, "its verdict does not count either: got "
    .. stats.rework_total)
end

-- `done ... not-planned` is not a completed item either.
local function test_a_not_planned_done_is_not_completed()
  local events: {Event} = {
    take(100, "item0005", 0),
    done(150, "item0005", "not-planned"),
  }
  local stats = flowstats.stats_of(events)
  assert(#stats.items == 0, "not-planned is not completed")
end

-- Summary medians over a three-item set, plus the rework pair summed
-- across them.
local function test_summary_medians_over_three_items()
  local events: {Event} = {
    take(0, "a", 0), verdict(5, "a", "accept"), done(10, "a", "completed"),
    take(0, "b", 0), verdict(5, "b", "request changes"),
    verdict(6, "b", "accept"), done(30, "b", "completed"),
    take(0, "c", 0), done(50, "c", "completed"),
  }
  local stats = flowstats.stats_of(events)
  assert(#stats.items == 3, "three completed items: got " .. #stats.items)
  assert(stats.lead_p50_s == 30,
    "median of 10, 30, 50 is 30: got " .. stats.lead_p50_s)
  assert(stats.lead_p90_s == 50,
    "p90 of 10, 30, 50 is 50: got " .. stats.lead_p90_s)
  assert(stats.rework_total == 3, "three verdicts across a and b: got "
    .. stats.rework_total)
  assert(stats.rework_accepts == 1, "one request-changes among them: got "
    .. stats.rework_accepts)
  assert(stats.bounces == 0, "no drops in this set")
end
