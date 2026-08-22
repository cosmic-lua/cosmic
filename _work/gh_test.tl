#!/usr/bin/env cosmic
-- The merge-outcome classifier: `is_merged` and `refusal` are pure
-- over a literal `gh.Result`, so these run with no network and no
-- token — the transport (`gh.merge` itself) is exercised only through
-- the board's own land flow, which needs a real repo and token.

local gh = require("_work.gh")

-- A 403 is a permission wall the client hit, not a failed diff, and
-- the recovery is actionable by the session that hit it: merge the
-- request by another route, then re-run `land`, which takes the
-- already-merged path. The message names that verb rather than
-- deferring to a maintainer, and still ends with GitHub's own detail
-- verbatim.
local function test_refusal_names_the_permission_wall()
  local msg = gh.refusal(1196, {status = 403, detail = "d"})
  assert(msg:sub(1, 9) == "REFUSED (", "got: " .. msg)
  assert(msg:find("permission refusal, not the diff", 1, true) ~= nil,
    "got: " .. msg)
  assert(msg:find("another route", 1, true) ~= nil,
    "it names the out-of-band merge: " .. msg)
  assert(msg:find("`gitboard land <id>`", 1, true) ~= nil,
    "it names land as the recovery verb: " .. msg)
  assert(msg:find("ask a maintainer", 1, true) == nil,
    "it no longer defers to a maintainer: " .. msg)
  assert(msg:sub(-2) == "d)", "got: " .. msg)
  local moved = gh.refusal(1196, {status = 409, detail = "d"})
  local generic = gh.refusal(1196, {status = 500, detail = "d"})
  assert(msg ~= moved, "the permission wall is not a moved head")
  assert(msg ~= generic, "nor the generic failure")
end
test_refusal_names_the_permission_wall()

-- A 409 is the `sha` guard firing on the server: the head moved
-- between the accept and the PUT, so nothing was merged and the
-- recovery is a re-review, not a re-run.
local function test_refusal_names_the_moved_head()
  local msg = gh.refusal(88, {status = 409, detail = "d"})
  assert(msg:find("409", 1, true) ~= nil, "got: " .. msg)
  assert(msg:find("moved between the accept and the merge", 1, true) ~= nil,
    "got: " .. msg)
  assert(msg:find("#88", 1, true) ~= nil, "it names the PR: " .. msg)
  local wall = gh.refusal(88, {status = 403, detail = "d"})
  local generic = gh.refusal(88, {status = 500, detail = "d"})
  assert(msg ~= wall, "a moved head is not the permission wall")
  assert(msg ~= generic, "nor the generic failure")
end
test_refusal_names_the_moved_head()

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

-- A non-empty repo short-circuits before touching git — no store root
-- is ever read, so a bogus one proves the short-circuit rather than
-- masking a git call that happened to succeed.
local function test_slug_short_circuits_on_a_set_repo()
  local slug = gh.slug({root = "/does/not/exist"}, "whilp/cosmopolitan")
  assert(slug == "whilp/cosmopolitan", "got: " .. tostring(slug))
end
test_slug_short_circuits_on_a_set_repo()
