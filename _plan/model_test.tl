#!/usr/bin/env cosmic
local model = require("_plan.model")

local type Issue = model.Issue
local type Board = model.Board

--- A minimal ready-bar-complete body for tests.
local READY_BODY < const > = [[
## Goal
G4 — via epic #12

## Change
Add the verb.

## Non-goals
No contract changes.

## Acceptance
`--make ci` ends `ci: PASS`.

## Enablement
none needed
]]

local record IssueOpts
  epic: boolean
  body: string
end

local function issue(n: integer, opts?: IssueOpts): Issue
  local i: Issue = {
    number = n,
    title = "issue " .. tostring(n),
    body = READY_BODY,
    url = "https://example.invalid/" .. tostring(n),
  }
  if opts then
    if opts.epic then i.epic = true end
    if opts.body then i.body = opts.body end
  end
  return i
end

local function all_open(_n: integer): boolean
  return true
end

local function all_closed(_n: integer): boolean
  return false
end

local function test_column_of()
  local col = model.column_of({"perf", "plan:ready", "plan:epic"})
  assert(col == "ready", "got: " .. tostring(col))
  assert(model.column_of({"perf"}) == nil, "expected nil without plan label")
  assert(model.column_of({"plan:bogus"}) == nil, "expected nil for bogus column")
end
test_column_of()

local function test_has_marker()
  assert(model.has_marker({"plan:epic"}, "epic"), "epic marker missed")
  assert(not model.has_marker({"plan:ready"}, "epic"), "false epic marker")
end
test_has_marker()

local function test_ready_gaps_complete()
  local gaps = model.ready_gaps(READY_BODY)
  assert(#gaps == 0, "unexpected gaps: " .. table.concat(gaps, ", "))
end
test_ready_gaps_complete()

local function test_ready_gaps_missing()
  local gaps = model.ready_gaps("## Goal\nG1\n\n## Change\nstuff\n")
  assert(#gaps == 3, "expected 3 gaps, got " .. tostring(#gaps))
  assert(gaps[1] == "Non-goals", "got: " .. tostring(gaps[1]))
  assert(gaps[2] == "Acceptance", "got: " .. tostring(gaps[2]))
  assert(gaps[3] == "Enablement", "got: " .. tostring(gaps[3]))
end
test_ready_gaps_missing()

local function test_ready_gaps_case_and_level()
  local gaps = model.ready_gaps(
    "# goal\nx\n### CHANGE\nx\n## non-goals\nx\n## acceptance\nx\n## enablement\nx\n")
  assert(#gaps == 0, "case/level should not matter: " .. table.concat(gaps, ", "))
end
test_ready_gaps_case_and_level()

local function test_blockers()
  local body = "## Enablement\nBlocked by: #99 and #100\nprose\nblocked by #7\n"
  local got = model.blockers(body)
  assert(#got == 3, "expected 3 blockers, got " .. tostring(#got))
  assert(got[1] == 99 and got[2] == 100 and got[3] == 7,
    ("got: %d %d %d"):format(got[1], got[2], got[3]))
  assert(#model.blockers("no blockers here #5") == 0, "false blocker")
end
test_blockers()

local function test_oldest_first_sorts_copy()
  local board: Board = {ready = {issue(5), issue(2), issue(9)}}
  local sorted = model.oldest_first(board, "ready")
  assert(sorted[1].number == 2 and sorted[3].number == 9, "sort broken")
  assert(board["ready"][1].number == 5, "input mutated")
  assert(#model.oldest_first(board, "doing") == 0, "missing column not empty")
end
test_oldest_first_sorts_copy()

local function test_wip_violations()
  local board: Board = {doing = {issue(1), issue(2), issue(3)}}
  local v = model.wip_violations(board)
  assert(#v == 1, "expected one violation, got " .. tostring(#v))
  assert(v[1] == "doing 3/2 over limit", "got: " .. v[1])
end
test_wip_violations()

local function test_implementer_pulls_oldest_unblocked()
  local blocked = issue(1, {body = "## Goal\nBlocked by #50\n"})
  local board: Board = {ready = {issue(3), blocked, issue(8, {epic = true})}}
  local action = assert(model.next_action(board, "implementer", all_open))
  assert(action.kind == "pull", "got: " .. action.kind)
  assert(action.issue.number == 3, "got: " .. tostring(action.issue.number))
end
test_implementer_pulls_oldest_unblocked()

local function test_implementer_pulls_when_blocker_closed()
  local blocked = issue(1, {body = "## Goal\nBlocked by #50\n"})
  local board: Board = {ready = {blocked, issue(3)}}
  local action = assert(model.next_action(board, "implementer", all_closed))
  assert(action.kind == "pull", "got: " .. action.kind)
  assert(action.issue.number == 1, "closed blocker should unblock")
end
test_implementer_pulls_when_blocker_closed()

local function test_implementer_finishes_doing_first()
  local board: Board = {doing = {issue(4)}, ready = {issue(6)}}
  local action = assert(model.next_action(board, "implementer", all_open))
  assert(action.kind == "finish", "got: " .. action.kind)
  assert(action.issue.number == 4, "got: " .. tostring(action.issue.number))
  assert(action.alt and action.alt.number == 6, "fallback should be #6")
end
test_implementer_finishes_doing_first()

local function test_implementer_idle_when_all_blocked()
  local board: Board = {ready = {issue(8, {epic = true})}}
  local action = assert(model.next_action(board, "implementer", all_open))
  assert(action.kind == "none", "got: " .. action.kind)
  assert(action.reason:find("planner", 1, true) ~= nil, "reason: " .. action.reason)
end
test_implementer_idle_when_all_blocked()

local function test_implementer_none_names_review_bottleneck()
  local board: Board = {review = {issue(4), issue(5)}}
  local action = assert(model.next_action(board, "implementer", all_open))
  assert(action.kind == "none", "got: " .. action.kind)
  assert(action.reason:find("2 issue(s) await planner review", 1, true) ~= nil,
    "reason: " .. action.reason)
end
test_implementer_none_names_review_bottleneck()

local function test_planner_reviews_first()
  local board: Board = {
    review = {issue(9), issue(7)},
    shaping = {issue(1)},
  }
  local action = assert(model.next_action(board, "planner", all_open))
  assert(action.kind == "review", "got: " .. action.kind)
  assert(action.issue.number == 7, "oldest review first")
end
test_planner_reviews_first()

local function test_planner_refines_when_ready_has_slack()
  local board: Board = {shaping = {issue(2)}}
  local action = assert(model.next_action(board, "planner", all_open))
  assert(action.kind == "refine", "got: " .. action.kind)
  assert(action.issue.number == 2, "got: " .. tostring(action.issue.number))
end
test_planner_refines_when_ready_has_slack()

local function test_planner_intakes_when_shaping_has_slack()
  local board: Board = {}
  local action = assert(model.next_action(board, "planner", all_open))
  assert(action.kind == "intake", "got: " .. action.kind)
  assert(action.reason:find("goals", 1, true) ~= nil, "reason: " .. action.reason)
end
test_planner_intakes_when_shaping_has_slack()

local function test_planner_none_when_saturated()
  local shaping: {Issue} = {}
  local ready: {Issue} = {}
  for n = 1, model.LIMITS["shaping"] do
    shaping[#shaping + 1] = issue(n)
  end
  for n = 11, 10 + model.LIMITS["ready"] do
    ready[#ready + 1] = issue(n)
  end
  local board: Board = {shaping = shaping, ready = ready}
  local action = assert(model.next_action(board, "planner", all_open))
  assert(action.kind == "none", "got: " .. action.kind)
end
test_planner_none_when_saturated()

local function test_unknown_role_errors()
  local action, err = model.next_action({}, "manager", all_open)
  assert(action == nil, "expected nil action")
  assert(err ~= nil and err:find("unknown role", 1, true) ~= nil,
    "err: " .. tostring(err))
end
test_unknown_role_errors()
