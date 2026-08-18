#!/usr/bin/env cosmic
-- The merge-outcome classifier: `is_merged` and `refusal` are pure
-- over a literal `gh.Result`, so these run with no network and no
-- token — the transport (`gh.merge` itself) is exercised only through
-- the board's own land flow, which needs a real repo and token.

local gh = require("_work.gh")

-- A 403 is a permission wall, not a failed diff: the message says so,
-- names the PR, and tells the operator what to do about it, ending
-- with GitHub's own detail verbatim.
local function test_refusal_names_the_permission_wall()
  local msg = gh.refusal(1196, {status = 403, detail = "d"})
  assert(msg:sub(1, 9) == "REFUSED (", "got: " .. msg)
  assert(msg:find("permission refusal, not the diff", 1, true) ~= nil,
    "got: " .. msg)
  assert(msg:find("ask a maintainer", 1, true) ~= nil, "got: " .. msg)
  assert(msg:sub(-2) == "d)", "got: " .. msg)
end
test_refusal_names_the_permission_wall()

-- Every other non-2xx is a failed merge attempt, not a permission
-- refusal — nothing was merged, and re-running land is the recovery.
local function test_refusal_reports_other_failures_as_error()
  local msg = gh.refusal(2, {status = 500, detail = "d"})
  assert(msg:sub(1, 7) == "ERROR (", "got: " .. msg)
  assert(msg:find("re-run land", 1, true) ~= nil, "got: " .. msg)
end
test_refusal_reports_other_failures_as_error()

-- `is_merged` reads the status field, nothing else.
local function test_is_merged_reads_the_status()
  assert(gh.is_merged({status = 200}) == true)
  assert(gh.is_merged({status = 403}) == false)
  assert(gh.is_merged({status = 500}) == false)
end
test_is_merged_reads_the_status()
