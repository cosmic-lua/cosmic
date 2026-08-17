#!/usr/bin/env cosmic
local close = require("_work.close")

local function test_state_reason_maps_both_spellings()
  assert(close.state_reason("completed") == "completed",
    "completed is the API's spelling already")
  assert(close.state_reason("not-planned") == "not_planned",
    "the flag's hyphen becomes the API's underscore")
end
test_state_reason_maps_both_spellings()

local function test_state_reason_refuses_anything_else()
  assert(close.state_reason("not_planned") == nil,
    "the API spelling is not the flag's spelling")
  assert(close.state_reason("duplicate") == nil,
    "a reason GitHub does not record is not accepted")
  assert(close.state_reason("") == nil, "an empty reason is not a reason")
end
test_state_reason_refuses_anything_else()

local function test_admits_close_from_the_planner_phases()
  assert(close.admits_close({"work:plan"}),
    "shaping decides an issue will not be worked")
  assert(close.admits_close({"work:plan", "work:finding"}),
    "a finding triaged away closes from plan")
  assert(close.admits_close({"work:check"}),
    "a verdict on a deliverable with nothing to merge closes from check")
end
test_admits_close_from_the_planner_phases()

local function test_admits_close_refuses_work_in_flight()
  assert(not close.admits_close({"work:ready"}),
    "queued work leaves ready by a move, not a close")
  assert(not close.admits_close({"work:do"}),
    "claimed work would vanish mid-flow")
  assert(not close.admits_close({"work:land"}),
    "accepted work closes through its merge")
end
test_admits_close_refuses_work_in_flight()

local function test_admits_close_off_the_board()
  assert(close.admits_close({}), "an issue on no phase carries no card")
  assert(close.admits_close({"perf"}), "a non-phase label is not a phase")
end
test_admits_close_off_the_board()

local function test_admits_close_reads_the_older_label_spelling()
  assert(not close.admits_close({"plan:doing"}),
    "the older spelling of do is still work in flight")
  assert(close.admits_close({"plan:shaping"}),
    "the older spelling of plan still admits a close")
end
test_admits_close_reads_the_older_label_spelling()
