#!/usr/bin/env cosmic
local github = require("_plan.github")

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
