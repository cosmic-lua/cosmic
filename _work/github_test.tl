#!/usr/bin/env cosmic
local github = require("_work.github")

local type RawIssue = github.RawIssue

local function raw(n: integer, is_pr: boolean): RawIssue
  local i: RawIssue = {number = n, title = "t" .. tostring(n)}
  if is_pr then
    i.pull_request = {}
  end
  return i
end

local function test_only_issues_drops_pull_requests()
  local mixed: {RawIssue} = {raw(1, false), raw(2, true), raw(3, false)}
  local issues = github.only_issues(mixed)
  assert(#issues == 2, "expected 2 issues, got " .. tostring(#issues))
  assert(issues[1].number == 1 and issues[2].number == 3,
    ("got: %d %d"):format(issues[1].number, issues[2].number))
end
test_only_issues_drops_pull_requests()

local function test_only_issues_empty()
  assert(#github.only_issues({}) == 0, "empty in, empty out")
end
test_only_issues_empty()

local function test_issue_patch_sends_only_supplied_fields()
  local both = github.issue_patch("t", "b")
  assert(both["title"] == "t" and both["body"] == "b", "both fields ride")
  local only_body = github.issue_patch(nil, "b")
  assert(only_body["title"] == nil, "an unsupplied title stays out")
  assert(only_body["body"] == "b", "the body rides")
  local only_title = github.issue_patch("t", nil)
  assert(only_title["body"] == nil, "an unsupplied body stays out")
  assert(only_title["title"] == "t", "the title rides")
end
test_issue_patch_sends_only_supplied_fields()

local function test_issue_patch_never_sends_labels()
  local p = github.issue_patch("t", "b")
  assert(p["labels"] == nil, "phases move through move, never edit")
  assert(github.issue_patch(nil, nil)["labels"] == nil, "empty patch is empty")
end
test_issue_patch_never_sends_labels()
