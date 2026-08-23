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
test_slug_short_circuits_on_a_set_repo()

-- With no repo field the slug comes from origin, so a checkout that
-- has no origin can address nothing: that is a named error, not a
-- guess at a default repository.
local function test_slug_without_an_origin_is_an_error()
  local s = fixture.init_state_repo("gh-slug")
  local slug, err = gh.slug(s, "")
  assert(slug == nil, "a checkout with no origin addresses nothing")
  assert(err:find("no origin remote", 1, true) ~= nil, "got: " .. err)
end
test_slug_without_an_origin_is_an_error()
