#!/usr/bin/env cosmic
-- The flow numbers are only as good as the parse behind them, so the
-- parse is asserted over literal commit events rather than a git
-- fixture: the three transition subjects, the verdict shape with and
-- without the session that judged it, and the squash-merge PR titles
-- that share the branch and must yield nothing. Dwell and counts are
-- then asserted over transitions built the same way, and the report
-- over both — no git, no network, no stdout capture.

local item = require("_work.item")
local stat = require("_work.flowstat")
local store = require("_work.store")

--- One commit, shaped as `store.history` hands it over.
--- @param at string ISO 8601 commit time
--- @param subject string The commit subject
--- @return store.Event The event
local function ev(at: string, subject: string): store.Event
  return {sha = "abc1234", at = at, subject = subject}
end

--- One item's whole life, newest first as git logs it, with the
--- non-transition subjects that surround it on the same branch.
local function one_item_log(): {store.Event}
  return {
    ev("2026-08-20T15:00:00+00:00", "done 3ICDOfPj completed (from land)"),
    ev("2026-08-20T14:00:00+00:00", "verdict 3ICDOfPj accept (check -> land)"),
    ev("2026-08-20T12:30:00+00:00", "move 3ICDOfPj do -> check"),
    ev("2026-08-20T12:00:00+00:00", "move 3ICDOfPj ready -> do"),
    ev("2026-08-20T11:00:00+00:00", "spec 3ICDOfPj"),
    ev("2026-08-20T10:30:00+00:00", "attach 3ICDOfPj under 3HyRdT1J"),
    ev("2026-08-20T10:00:00+00:00", "new 3ICDOfPj a slice of the work"),
  }
end

local function test_parse_reads_the_three_transition_shapes()
  local ts = stat.parse(one_item_log())
  assert(#ts == 4, ("4 transitions, got %d"):format(#ts))
  assert(ts[1].id == "3ICDOfPj", ts[1].id)
  assert(ts[1].from == "land" and ts[1].to == "", ts[1].from .. "/" .. ts[1].to)
  assert(ts[1].verdict == "completed", ts[1].verdict)
  assert(ts[2].from == "check" and ts[2].to == "land", ts[2].to)
  assert(ts[2].verdict == "accept", ts[2].verdict)
  assert(ts[3].from == "do" and ts[3].to == "check", ts[3].to)
  assert(ts[3].verdict == "", "a plain move carries no verdict")
  assert(ts[4].at == "2026-08-20T12:00:00+00:00", ts[4].at)
end
test_parse_reads_the_three_transition_shapes()

local function test_parse_accepts_a_verdict_with_or_without_a_session()
  local ts = stat.parse({
      ev("2026-08-20T14:00:00+00:00",
        "verdict 3ICDOfPj accept (check -> land) by session-a"),
      ev("2026-08-20T13:00:00+00:00",
        "verdict 3HyRdT1J request changes (check -> do)"),
      ev("2026-08-20T12:00:00+00:00", "verdict 3IHGsSpm reject (check -> plan)"),
    })
  assert(#ts == 3, ("3 verdicts, got %d"):format(#ts))
  assert(ts[1].verdict == "accept", ts[1].verdict)
  assert(ts[1].from == "check" and ts[1].to == "land", ts[1].to)
  assert(ts[2].verdict == "request changes", ts[2].verdict)
  assert(ts[2].to == "do", ts[2].to)
  assert(ts[3].verdict == "reject", ts[3].verdict)
  assert(ts[3].to == "plan", ts[3].to)
end
test_parse_accepts_a_verdict_with_or_without_a_session()

local function test_parse_ignores_squash_merge_pr_titles()
  local ts = stat.parse({
      ev("2026-08-20T14:00:00+00:00",
        "verdict: an accept reads the request it judges (#1322)"),
      ev("2026-08-20T13:00:00+00:00",
        "verdict: builder review is a refusal, and the log says who judged (#1321)"),
      ev("2026-08-20T12:00:00+00:00", "move: the ready bar checks a Non-goal (#1300)"),
      ev("2026-08-20T11:00:00+00:00", "done: the stall capture (from the queue) (#1301)"),
      ev("2026-08-20T10:00:00+00:00", "work: the board rebuilds itself (#1298)"),
    })
  assert(#ts == 0, ("a PR title is not a transition, got %d"):format(#ts))
end
test_parse_ignores_squash_merge_pr_titles()

local function test_parse_ignores_the_other_board_subjects()
  local ts = stat.parse({
      ev("2026-08-20T14:00:00+00:00", "block 3ICDOfPj on 3HyRdT1J"),
      ev("2026-08-20T13:00:00+00:00", "unblock 3ICDOfPj on 3HyRdT1J"),
      ev("2026-08-20T12:00:00+00:00", "set 3ICDOfPj in do"),
      ev("2026-08-20T11:00:00+00:00", "retitle 3ICDOfPj to the real defect"),
    })
  assert(#ts == 0, ("no transitions, got %d"):format(#ts))
end
test_parse_ignores_the_other_board_subjects()

local function test_dwell_measures_the_span_between_two_transitions()
  local d = stat.dwell(stat.parse({
        ev("2026-08-20T13:00:00+00:00", "move 3ICDOfPj do -> check"),
        ev("2026-08-20T10:00:00+00:00", "move 3ICDOfPj ready -> do"),
      }))
  local w = d["do"]
  assert(w ~= nil, "the item entered and left `do`")
  assert(w.phase == "do", w.phase)
  assert(w.entries == 1, ("1 ended dwell, got %d"):format(w.entries))
  assert(w.median_s == 10800, ("3h, got %d"):format(w.median_s))
  assert(w.p90_s == 10800, ("3h, got %d"):format(w.p90_s))
end
test_dwell_measures_the_span_between_two_transitions()

local function test_dwell_skips_the_phase_an_item_is_still_in()
  local d = stat.dwell(stat.parse({
        ev("2026-08-20T13:00:00+00:00", "move 3ICDOfPj do -> check"),
        ev("2026-08-20T10:00:00+00:00", "move 3ICDOfPj ready -> do"),
      }))
  assert(d["check"] == nil, "the item has not left `check`")
  assert(d["ready"] == nil, "nothing recorded it entering `ready`")
end
test_dwell_skips_the_phase_an_item_is_still_in()

local function test_dwell_reports_only_the_ended_dwells_of_a_phase()
  local d = stat.dwell(stat.parse({
        ev("2026-08-20T12:00:00+00:00", "move 3HyRdT1J ready -> do"),
        ev("2026-08-20T11:00:00+00:00", "move 3HyRdT1J plan -> ready"),
        ev("2026-08-20T10:00:00+00:00", "move 3ICDOfPj plan -> ready"),
      }))
  local w = d["ready"]
  assert(w ~= nil, "one item left `ready`")
  assert(w.entries == 1, ("the other is still there, got %d"):format(w.entries))
  assert(w.median_s == 3600, ("1h, got %d"):format(w.median_s))
end
test_dwell_reports_only_the_ended_dwells_of_a_phase()

local function test_dwell_aggregates_a_phase_over_every_item()
  local d = stat.dwell(stat.parse({
        ev("2026-08-20T10:20:00+00:00", "move 3IHGsSpm do -> check"),
        ev("2026-08-20T10:00:00+00:00", "move 3IHGsSpm ready -> do"),
        ev("2026-08-20T09:10:00+00:00", "move 3HyRdT1J do -> check"),
        ev("2026-08-20T09:00:00+00:00", "move 3HyRdT1J ready -> do"),
        ev("2026-08-20T08:30:00+00:00", "move 3ICDOfPj do -> check"),
        ev("2026-08-20T08:00:00+00:00", "move 3ICDOfPj ready -> do"),
      }))
  local w = d["do"]
  assert(w ~= nil, "three items left `do`")
  assert(w.entries == 3, ("3 dwells, got %d"):format(w.entries))
  -- Nearest rank over 600, 1200, 1800: the median is the middle
  -- observation and the 90th percentile the largest.
  assert(w.median_s == 1200, ("20m, got %d"):format(w.median_s))
  assert(w.p90_s == 1800, ("30m, got %d"):format(w.p90_s))
end
test_dwell_aggregates_a_phase_over_every_item()

local function test_dwell_reads_the_zone_offset_arithmetically()
  -- The two commits straddle a spring-forward: the wall clocks are two
  -- hours apart, the offsets differ, and the real span is one hour.
  local d = stat.dwell(stat.parse({
        ev("2026-03-08T03:30:00-04:00", "move 3ICDOfPj do -> check"),
        ev("2026-03-08T01:30:00-05:00", "move 3ICDOfPj ready -> do"),
      }))
  local w = d["do"]
  assert(w ~= nil, "the item left `do`")
  assert(w.median_s == 3600, ("1h, got %d"):format(w.median_s))
end
test_dwell_reads_the_zone_offset_arithmetically()

local function test_counts_tally_verdicts_endings_and_pulls()
  local c = stat.counts(stat.parse({
        ev("2026-08-20T16:00:00+00:00", "done 3IHGsSpm not-planned (from plan)"),
        ev("2026-08-20T15:00:00+00:00", "done 3ICDOfPj completed (from land)"),
        ev("2026-08-20T14:30:00+00:00", "verdict 3ICDOfPj accept (check -> land)"),
        ev("2026-08-20T14:00:00+00:00", "verdict 3HyRdT1J reject (check -> plan)"),
        ev("2026-08-20T13:30:00+00:00",
          "verdict 3IA4EtZQ request changes (check -> do) by session-b"),
        ev("2026-08-20T13:00:00+00:00", "move 3HyRdT1J ready -> do"),
        ev("2026-08-20T12:00:00+00:00", "move 3ICDOfPj ready -> do"),
        ev("2026-08-20T11:00:00+00:00", "move 3ICDOfPj plan -> ready"),
      }))
  assert(c["accept"] == 1, ("1 accept, got %d"):format(c["accept"]))
  assert(c["request changes"] == 1,
    ("1 request changes, got %d"):format(c["request changes"]))
  assert(c["reject"] == 1, ("1 reject, got %d"):format(c["reject"]))
  assert(c["completed"] == 1, ("1 completed, got %d"):format(c["completed"]))
  assert(c["pulls"] == 2, ("2 pulls, got %d"):format(c["pulls"]))
end
test_counts_tally_verdicts_endings_and_pulls()

local function test_counts_are_zero_when_nothing_happened()
  local c = stat.counts({})
  assert(c["accept"] == 0, "an unseen outcome counts zero, not nil")
  assert(c["request changes"] == 0, "same")
  assert(c["reject"] == 0, "same")
  assert(c["completed"] == 0, "same")
  assert(c["pulls"] == 0, "same")
end
test_counts_are_zero_when_nothing_happened()

local function test_report_prints_every_phase_and_one_counts_line()
  local lines, verdict = stat.report(stat.parse(one_item_log()))
  assert(#lines == #item.PHASES + 1,
    ("a line per phase plus counts, got %d"):format(#lines))
  for i, phase in ipairs(item.PHASES) do
    assert(lines[i]:sub(1, #phase) == phase, lines[i])
  end
  -- `do` is the fourth phase left to right, and the only one this log
  -- records a stint in.
  assert(lines[4]:find("dwell n=1 median 30m p90 30m", 1, true) ~= nil, lines[4])
  assert(lines[1]:find("dwell n=0", 1, true) ~= nil,
    "a phase nothing dwelt in still prints: " .. lines[1])
  local counted = lines[#lines]
  assert(counted:find("counts accept=1 request-changes=0 reject=0 "
      .. "completed=1 pulls=1", 1, true) ~= nil, counted)
  assert(verdict == "4 transition(s) across 1 item(s)", verdict)
end
test_report_prints_every_phase_and_one_counts_line()
