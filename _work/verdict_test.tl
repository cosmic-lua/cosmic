#!/usr/bin/env cosmic
local gh = require("_work.github")
local verdict = require("_work.verdict")

local type Standing = verdict.Standing
local type Comment = verdict.Comment

local function test_parse_reads_every_kind()
  assert(verdict.parse("work-verdict: accept") == "accept", "accept")
  assert(verdict.parse("work-verdict: request changes") == "request changes",
    "request changes")
  assert(verdict.parse("work-verdict: reject") == "reject", "reject")
end
test_parse_reads_every_kind()

local function test_parse_reads_the_older_spelling()
  assert(verdict.parse("plan-verdict: request changes\n\ngaps below")
    == "request changes", "the plan- spelling open PRs carry still parses")
end
test_parse_reads_the_older_spelling()

local function test_parse_anchors_the_first_line()
  assert(verdict.parse("lgtm\nwork-verdict: accept") == nil,
    "a verdict on a later line is prose, not a verdict")
  assert(verdict.parse("quoting work-verdict: accept") == nil,
    "a prose-prefixed first line is not a verdict")
end
test_parse_anchors_the_first_line()

local function test_parse_tolerates_crlf()
  assert(verdict.parse("work-verdict: accept\r\nmore") == "accept",
    "a \\r\\n body still parses on the first line")
end
test_parse_tolerates_crlf()

local function test_parse_rejects_unknown_kinds()
  assert(verdict.parse("work-verdict: maybe") == nil, "unknown kind")
  assert(verdict.parse("") == nil, "an empty body carries no verdict")
end
test_parse_rejects_unknown_kinds()

local function test_closes_anchors_the_digit_run()
  assert(verdict.closes("Closes #7", 7), "Closes #7 closes issue 7")
  assert(verdict.closes("fixes\n\ncloses #7\n", 7), "lowercase closes too")
  assert(not verdict.closes("Closes #70", 7), "#70 is not #7")
  assert(not verdict.closes("no reference", 7), "no reference closes nothing")
end
test_closes_anchors_the_digit_run()

local function test_latest_takes_the_newest_verdict()
  local v = verdict.latest({
      {body = "work-verdict: request changes", created_at = "2026-08-16T13:59:03Z"},
      {body = "rework pushed", created_at = "2026-08-16T14:27:27Z"},
      {body = "work-verdict: accept", created_at = "2026-08-16T18:14:19Z"},
      {body = "work-verdict: request changes", created_at = "2026-08-16T19:16:16Z"},
    })
  assert(v ~= nil, "a list with verdicts has a standing one")
  assert(v.kind == "request changes", "got: " .. tostring(v.kind))
  assert(v.at == "2026-08-16T19:16:16Z", "got: " .. tostring(v.at))
end
test_latest_takes_the_newest_verdict()

local function test_latest_is_nil_without_a_verdict()
  assert(verdict.latest({}) == nil, "no comments, no verdict")
  assert(verdict.latest({{body = "lgtm", created_at = "2026-08-16T13:00:00Z"}})
    == nil, "prose is not a verdict")
end
test_latest_is_nil_without_a_verdict()

local function test_is_answered_compares_the_stamps()
  assert(verdict.is_answered("2026-08-16T19:16:16Z", "2026-08-16T19:58:21Z"),
    "a commit after the verdict answers it")
  assert(not verdict.is_answered("2026-08-16T19:16:16Z", "2026-08-16T17:58:21Z"),
    "a commit before the verdict does not")
  assert(not verdict.is_answered("2026-08-16T19:16:16Z", ""),
    "an unknown head never clears a standing verdict")
end
test_is_answered_compares_the_stamps()

--- One timeline entry naming a cross-referencing issue or PR.
local function crossref(number: integer, state: string, body: string,
    is_pr: boolean): gh.RawTimelineEntry
  local source: gh.RawIssue = {
    number = number,
    state = state,
    body = body,
  }
  if is_pr then
    source.pull_request = {["url"] = "https://api.github.com/x"}
  end
  return {event = "cross-referenced", created_at = "2026-08-16T06:30:59Z",
    source = {issue = source}}
end

local function test_linked_pr_takes_the_open_closing_pr()
  local entries: {gh.RawTimelineEntry} = {
    crossref(1158, "closed", "Closes #1156", true),
    crossref(1202, "open", "mentions #1156 in prose", false),
    crossref(1185, "open", "Closes #1156\n\n## What this does", true),
  }
  assert(verdict.linked_pr(entries, 1156) == 1185,
    "the open PR closing the issue is the linked one")
end
test_linked_pr_takes_the_open_closing_pr()

local function test_linked_pr_is_zero_without_one()
  local entries: {gh.RawTimelineEntry} = {
    crossref(1202, "open", "mentions #1156", false),
    crossref(1185, "open", "Closes #1157", true),
  }
  assert(verdict.linked_pr(entries, 1156) == 0,
    "a mention is not a close, and another issue's PR is not this one's")
  assert(verdict.linked_pr({}, 1156) == 0, "no timeline, no PR")
end
test_linked_pr_is_zero_without_one()

local function test_linked_pr_prefers_the_highest_number()
  local entries: {gh.RawTimelineEntry} = {
    crossref(1209, "open", "Closes #1179", true),
    crossref(1185, "open", "Closes #1179", true),
  }
  assert(verdict.linked_pr(entries, 1179) == 1209,
    "the newest open attempt supersedes an earlier one")
end
test_linked_pr_prefers_the_highest_number()

--- The #1156 / PR #1185 state this gate was built from: three request-
--- changes verdicts, the newest at 22:43:45Z, against a head committed
--- at 17:58:21Z.
local function unanswered(): Standing
  return {
    pr = 1185,
    url = "https://github.com/whilp/cosmic/pull/1185",
    kind = "request changes",
    at = "2026-08-16T22:43:45Z",
    head_sha = "3b5502d375bf06c3288d05a9deca0a2bf36b0ef1",
    head_at = "2026-08-16T17:58:21Z",
    answered = false,
  }
end

local function test_blocks_check_on_an_unanswered_request()
  local msg = verdict.blocks_check(unanswered())
  assert(msg ~= nil, "an unanswered request-changes blocks the move")
  assert(msg:find("PR #1185", 1, true), "got: " .. tostring(msg))
  assert(msg:find("2026-08-16T22:43:45Z", 1, true), "got: " .. tostring(msg))
  assert(msg:find("3b5502d", 1, true), "the head it is judged against")
end
test_blocks_check_on_an_unanswered_request()

local function test_blocks_check_passes_everything_else()
  local answered = unanswered()
  answered.answered = true
  assert(verdict.blocks_check(answered) == nil, "pushed rework passes")
  local accepted = unanswered()
  accepted.kind = "accept"
  assert(verdict.blocks_check(accepted) == nil, "an accept passes")
  local fresh = unanswered()
  fresh.kind = nil
  assert(verdict.blocks_check(fresh) == nil, "a PR with no verdict passes")
  assert(verdict.blocks_check({pr = 0, answered = false}) == nil,
    "no PR, nothing to answer")
end
test_blocks_check_passes_everything_else()

local function test_line_marks_the_unanswered_case()
  local out = verdict.line(unanswered())
  assert(out:find("UNANSWERED", 1, true), "got: " .. out)
  assert(out:find("request changes on PR #1185", 1, true), "got: " .. out)
  assert(out:find("head 3b5502d", 1, true), "the short head SHA: " .. out)
  assert(out:find("https://github.com/whilp/cosmic/pull/1185", 1, true),
    "the PR URL: " .. out)
end
test_line_marks_the_unanswered_case()

local function test_line_renders_the_quiet_cases()
  local answered = unanswered()
  answered.answered = true
  assert(not verdict.line(answered):find("UNANSWERED", 1, true),
    "pushed rework is not unanswered")
  local accepted = unanswered()
  accepted.kind = "accept"
  local out = verdict.line(accepted)
  assert(not out:find("UNANSWERED", 1, true),
    "the decoration is for request-changes alone: " .. out)
  assert(verdict.line({pr = 0, answered = false}):find("no open PR", 1, true),
    "an issue with no PR says so")
  local fresh = unanswered()
  fresh.kind = nil
  assert(verdict.line(fresh):find("none yet on PR #1185", 1, true),
    "a PR awaiting its first verdict says so")
end
test_line_renders_the_quiet_cases()

--- A `request changes` verdict comment, with the given `enable:` line
--- (or none) tacked on as its own trailing line.
local function reject_comment(enable_line: string): {Comment}
  local body = "work-verdict: request changes\n\nsome gap"
  if enable_line then
    body = body .. "\n\n" .. enable_line
  end
  return {{body = body, created_at = "2026-08-16T22:43:45Z"}}
end

local function test_latest_captures_a_numbered_enable_trailer()
  local v = verdict.latest(reject_comment("enable: #1243"))
  assert(v ~= nil, "the comment still parses to a verdict")
  assert(v.enable == "enable: #1243", "got: " .. tostring(v.enable))
end
test_latest_captures_a_numbered_enable_trailer()

local function test_latest_captures_a_reasoned_none_trailer()
  local v = verdict.latest(
    reject_comment("enable: none (the ready-bar gap was this issue's own)"))
  assert(v.enable == "enable: none (the ready-bar gap was this issue's own)",
    "got: " .. tostring(v.enable))
end
test_latest_captures_a_reasoned_none_trailer()

local function test_latest_does_not_parse_a_reasonless_none()
  local v = verdict.latest(reject_comment("enable: none"))
  assert(v.enable == nil,
    "'enable: none' with no parenthesised reason is not the grammar; got: "
    .. tostring(v.enable))
end
test_latest_does_not_parse_a_reasonless_none()

local function test_latest_leaves_enable_nil_when_absent()
  local v = verdict.latest(reject_comment(nil))
  assert(v.enable == nil, "a comment with no enable: line carries none")
end
test_latest_leaves_enable_nil_when_absent()

--- A `request changes` standing verdict, optionally carrying an
--- `enable:` trailer, the state `blocks_send_back` reads.
local function rejected(enable: string): Standing
  local s = unanswered()
  s.enable = enable
  return s
end

local function test_blocks_send_back_passes_a_numbered_trailer()
  assert(verdict.blocks_send_back(rejected("enable: #1243")) == nil,
    "an 'enable: #N' trailer is the countermeasure filed")
end
test_blocks_send_back_passes_a_numbered_trailer()

local function test_blocks_send_back_passes_a_reasoned_none()
  assert(verdict.blocks_send_back(
      rejected("enable: none (the ready-bar gap was this issue's own)")) == nil,
    "an 'enable: none (<reason>)' trailer is the deliberate no-countermeasure case")
end
test_blocks_send_back_passes_a_reasoned_none()

local function test_blocks_send_back_refuses_a_reasonless_none()
  -- a bare "enable: none" never reaches Standing.enable (test above), so the
  -- Standing this call site sees is the same as the trailer-absent case
  local msg = verdict.blocks_send_back(rejected(nil))
  assert(msg ~= nil, "no parsed trailer means the countermeasure was not filed")
end
test_blocks_send_back_refuses_a_reasonless_none()

local function test_blocks_send_back_refuses_without_a_trailer()
  local msg = verdict.blocks_send_back(rejected(nil))
  assert(msg ~= nil, "a request-changes verdict with no trailer blocks the move")
  assert(msg:find("PR #1185", 1, true), "got: " .. tostring(msg))
  assert(msg:find("request changes", 1, true), "names the verdict kind: "
    .. tostring(msg))
  assert(msg:find("enable: #<issue>", 1, true), "names the numbered form: "
    .. tostring(msg))
  assert(msg:find("enable: none (<reason>)", 1, true), "names the none form: "
    .. tostring(msg))
end
test_blocks_send_back_refuses_without_a_trailer()

local function test_blocks_send_back_passes_an_accept_with_no_trailer()
  local accepted = rejected(nil)
  accepted.kind = "accept"
  assert(verdict.blocks_send_back(accepted) == nil,
    "an accept carries no trailer and must keep passing")
end
test_blocks_send_back_passes_an_accept_with_no_trailer()

local function test_blocks_send_back_passes_an_issue_with_no_pr()
  assert(verdict.blocks_send_back({pr = 0, answered = false}) == nil,
    "no PR closes the issue, so there is nothing to check a trailer against")
end
test_blocks_send_back_passes_an_issue_with_no_pr()

--- Mirrors the guard in `_work/verbs.tl`'s `cmd_move`: `blocks_send_back`
--- only runs when the move leaves `check` toward `do` or `plan` and
--- `--force` was not passed — the predicate itself carries no force
--- parameter, exactly like `blocks_check`.
local function gate(phase: string, target: string, force: boolean,
    s: Standing): string
  if phase == "check" and (target == "do" or target == "plan") and not force then
    return s and verdict.blocks_send_back(s)
  end
  return nil
end

local function test_force_bypasses_the_send_back_gate()
  assert(gate("check", "do", false, rejected(nil)) ~= nil,
    "without --force, a missing trailer blocks the move")
  assert(gate("check", "do", true, rejected(nil)) == nil,
    "--force bypasses the gate before blocks_send_back ever runs")
  assert(gate("check", "plan", true, rejected(nil)) == nil,
    "--force bypasses on the plan target too")
end
test_force_bypasses_the_send_back_gate()
