#!/usr/bin/env cosmic
-- The addressing half of the GitHub reads: which `owner/repo` a call
-- goes to, decided from the item's field or the checkout's origin.
-- That decision runs with no network and no token; the reads
-- themselves (`pull`, `checks`) need both, and are exercised only
-- through the board's own flow against a real repository.

local gh = require("_work.gh")
local fixture = require("_work.fixture")

-- A non-empty repo short-circuits before touching git — no store root
-- is ever read, so a bogus one proves the short-circuit rather than
-- masking a git call that happened to succeed.
local function test_slug_short_circuits_on_a_set_repo()
  local slug = gh.slug({root = "/does/not/exist"}, "whilp/cosmopolitan")
  assert(slug == "whilp/cosmopolitan", "got: " .. tostring(slug))
end

-- With no repo field the slug comes from origin, so a checkout that
-- has no origin can address nothing: that is a named error, not a
-- guess at a default repository.
local function test_slug_without_an_origin_is_an_error()
  local s = fixture.init_state_repo("gh-slug")
  local slug, err = gh.slug(s, "")
  assert(slug == nil, "a checkout with no origin addresses nothing")
  assert(err:find("no origin remote", 1, true) ~= nil, "got: " .. err)
end

-- `head_state` is the pure classification `head_checks` composes with
-- a fetched pull and its check runs — exercised directly against
-- synthetic run lists, the same way `review_test.tl` exercises
-- `blocks_on_ci` directly, rather than only through a stub standing
-- in for the whole of `head_checks`.
local function test_head_state_is_green_when_every_run_completed_clean()
  assert(gh.head_state({
        {name = "ci", status = "completed", conclusion = "success"},
      }) == "green", "one clean completed run is green")
end

local function test_head_state_is_red_on_a_concluded_failure()
  assert(gh.head_state({
        {name = "ci", status = "completed", conclusion = "success"},
        {name = "build", status = "completed", conclusion = "failure"},
      }) == "red", "a concluded failure among the runs is red")
end

local function test_head_state_is_running_while_anything_is_incomplete()
  assert(gh.head_state({
        {name = "ci", status = "completed", conclusion = "success"},
        {name = "smoke", status = "in_progress", conclusion = ""},
      }) == "running", "one run still going, none failed yet, is running")
end

local function test_head_state_is_none_with_no_runs_at_all()
  assert(gh.head_state({}) == "none", "an empty run list is none")
end
