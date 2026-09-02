#!/usr/bin/env cosmic
-- The hold marker as a verb: a root whose win condition is verified is
-- HELD, not ended — it stays open, keeps its edges, and intake walks
-- past it — so the verbs pin the refusals that keep the marker honest
-- (a non-root, a finished root, no reason, a repeat) and the one-commit
-- round trip of setting and clearing it. A finished root is history on
-- both sides — `done` drops the marker it ends over, `unhold` refuses
-- to touch one — and the per-item rule that a parented item is never
-- held is pinned at `item.problems`, where a hand edit would meet it.
-- The scratch board harness is `_work.fixture`.

local check = require("cosmic.check")
local cmp = require("_work.gitcompare")
local fixture = require("_work.fixture")
local item = require("_work.item")
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

local function test_unhold_refuses_a_done_root()
  local s = init_state_repo("unhold-done")
  local root = root_with_leaf(s)
  -- Written by hand, not through the verbs: `done` now clears the
  -- marker, so the only way a done root carries it is an old board or
  -- a hand edit — exactly what the refusal has to hold against.
  local stale = check.must(store.load(s, root))
  stale.is_held = true
  stale.resolution = "not-planned"
  assert(store.save(s, stale, "hand-edit: a done root still marked held"))
  local before = commits(s)
  assert(cmp.cmd_unhold(s, root) ~= 0,
    "a done root is history, not a repair target: unhold refuses it")
  assert(commits(s) == before, "and the refusal writes nothing")
  local after = check.must(store.load(s, root))
  assert(after.is_held == true, "the marker on a done item is left as found")
  assert(after.resolution == "not-planned", "and so is the resolution")
end
test_unhold_refuses_a_done_root()

local function test_done_clears_the_marker_it_ends_over()
  local s = init_state_repo("done-held")
  local root = file_item(s, "an outcome verified, then ended", "")
  assert(cmp.cmd_hold(s, root, "verified by hand") == 0)
  assert(check.must(store.load(s, root)).is_held == true, "held before done")
  assert(verbs.cmd_done(s, root, "completed", false, "") == 0,
    "a held root ends like any open root")
  local ended = check.must(store.load(s, root))
  assert(ended.resolution == "completed", "the root is done")
  assert(not ended.is_held, "and a done item never carries the marker")
  assert(cmp.cmd_unhold(s, root) ~= 0, "so there is nothing to unhold")
end
test_done_clears_the_marker_it_ends_over()

local function test_problems_reports_a_held_parented_item()
  local s = init_state_repo("held-leaf")
  local root, leaf = root_with_leaf(s)
  local held_root = check.must(store.load(s, root))
  held_root.is_held = true
  assert(#item.problems(held_root) == 0, "a held root is a valid item")
  local held_leaf = check.must(store.load(s, leaf))
  held_leaf.is_held = true
  local problems = item.problems(held_leaf)
  local found = false
  for _, p in ipairs(problems) do
    if p:find("a parented item is never held", 1, true) then
      found = true
    end
  end
  assert(found, "is_held on a parented item is a problem: "
    .. table.concat(problems, "; "))
  assert(#problems == 1, "and the only one: " .. table.concat(problems, "; "))
end
test_problems_reports_a_held_parented_item()
