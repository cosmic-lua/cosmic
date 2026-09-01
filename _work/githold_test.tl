#!/usr/bin/env cosmic
-- The hold marker as a verb: a root whose win condition is verified is
-- HELD, not ended — it stays open, keeps its edges, and intake walks
-- past it — so the verbs pin the refusals that keep the marker honest
-- (a non-root, a finished root, no reason, a repeat) and the one-commit
-- round trip of setting and clearing it. The scratch board harness is
-- `_work.fixture`.

local check = require("cosmic.check")
local cmp = require("_work.gitcompare")
local fixture = require("_work.fixture")
local publish = require("_work.publish")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

local init_state_repo = fixture.init_state_repo
local file_item = fixture.file_item
local commits = fixture.commits
local root_with_leaf = fixture.root_with_leaf

local function test_hold_refuses_what_is_not_an_open_root()
  local s = init_state_repo("hold-refusals")
  local root, leaf = root_with_leaf(s)
  local spent = file_item(s, "an outcome already ended", "")
  assert(verbs.cmd_done(s, spent, "not-planned", false, "") == 0)
  local before = commits(s)
  assert(cmp.cmd_hold(s, leaf, "the slice merged") ~= 0,
    "a parented item is never held: holding is an outcome-root concept")
  assert(not check.must(store.load(s, leaf)).is_held, "and nothing was written")
  assert(cmp.cmd_hold(s, root, "") ~= 0, "a hold with no reason is refused")
  assert(cmp.cmd_hold(s, root, "   ") ~= 0, "a blank reason is no reason")
  assert(not check.must(store.load(s, root)).is_held, "the refusal wrote nothing")
  assert(cmp.cmd_hold(s, spent, "verified") ~= 0,
    "a finished root is history, not a hold target")
  assert(not check.must(store.load(s, spent)).is_held, "and stays unmarked")
  local missing = root:sub(1, -2) .. (root:sub(-1) == "A" and "B" or "A")
  assert(cmp.cmd_hold(s, missing, "verified") ~= 0, "an unknown id is refused")
  assert(commits(s) == before,
    ("refusals commit nothing: %d -> %d"):format(before, commits(s)))
end
test_hold_refuses_what_is_not_an_open_root()

local function test_hold_sets_the_marker_in_one_commit_and_once()
  local s = init_state_repo("hold-happy")
  local root = root_with_leaf(s)
  local before = commits(s)
  assert(cmp.cmd_hold(s, root, "G4's observable test passed on main") == 0,
    "holding an open root lands")
  assert(commits(s) == before + 1, "one hold, one commit")
  local held = check.must(store.load(s, root))
  assert(held.is_held == true, "the marker is on the stored item")
  assert(held.resolution == "", "and the root is still open — held is not done")
  local events = check.must(publish.history(s, root))
  assert(events[1].subject:match("^hold %w%w%w%w%w%w%w%w G4's observable test")
    ~= nil, "the reason rides in the commit subject: " .. events[1].subject)
  assert(cmp.cmd_hold(s, root, "again") ~= 0, "a second hold is a no-op refusal")
  assert(commits(s) == before + 1, "and writes no commit")
end
test_hold_sets_the_marker_in_one_commit_and_once()

local function test_unhold_clears_the_marker_in_one_commit()
  local s = init_state_repo("unhold")
  local root = root_with_leaf(s)
  local before = commits(s)
  assert(cmp.cmd_unhold(s, root) ~= 0, "unholding what is not held is refused")
  assert(commits(s) == before, "and writes nothing")
  assert(cmp.cmd_hold(s, root, "verified by hand") == 0)
  local mid = commits(s)
  assert(cmp.cmd_unhold(s, root) == 0, "a held root unholds")
  assert(commits(s) == mid + 1, "one unhold, one commit")
  local freed = check.must(store.load(s, root))
  assert(not freed.is_held, "the marker is gone from the stored item")
  local events = check.must(publish.history(s, root))
  assert(events[1].subject:match("^unhold %w%w%w%w%w%w%w%w$") ~= nil,
    "the subject names the release: " .. events[1].subject)
  assert(cmp.cmd_hold(s, root, "verified again") == 0,
    "and the root can be held again after a release")
end
test_unhold_clears_the_marker_in_one_commit()
