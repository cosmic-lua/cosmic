#!/usr/bin/env cosmic
-- The state verbs against scratch state repositories: `take`, `drop`
-- and `done`, their refusals, and the properties that hold across one
-- mutation — one commit per change, a spec bar and a doing bound that
-- bind the take of NEW work only, and a drop that clears every lock
-- together. What the sidecar itself has to say for an item to be
-- taken is `_work/gitspec_test.tl`.

local check = require("cosmic.check")
local child = require("cosmic.child")
local flow = require("_work.flow")
local publish = require("_work.publish")
local store = require("_work.store")
local fixture = require("_work.fixture")
local verbs = require("_work.gitverbs")
local graph = require("_work.gitgraph")
local vrd = require("_work.gitverdict")

local init_state_repo = fixture.init_state_repo
local init_shared = fixture.init_shared
local file_item = fixture.file_item
local commits = fixture.commits
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

-- The take of todo work is the pull, and it is where the spec bar
-- binds: an item whose sidecar misses a section is refused, refined,
-- then taken.
local function test_take_asks_the_spec_bar_of_todo_work()
  local s = init_state_repo("bar")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") ~= 0,
    "an unrefined spec is refused at take")
  assert(check.must(store.load(s, leaf)).claim == "", "and nothing is written")
  give_spec(s, leaf)
  local before = commits(s)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0,
    "a spec passing the bar is taken")
  assert(commits(s) == before + 1, "one mutation, one commit")
  local taken = check.must(store.load(s, leaf))
  assert(taken.claim == "session-a", "the claim is the lock")
  assert(#taken.builders == 1 and taken.builders[1] == "session-a",
    "and the builder is on the record")
end
test_take_asks_the_spec_bar_of_todo_work()

-- The incident, refused at the door: a mangled argv absorbing a
-- literal `--session` as the identity can no longer enter the claim,
-- the builders list, or — via the review-claim derivation — the
-- reviewer field.
local function test_take_refuses_a_flag_shaped_session()
  local s = init_state_repo("flagsession")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "--session", 0, false, "") ~= 0,
    "a flag-shaped claim is refused")
  local it = check.must(store.load(s, leaf))
  assert(it.claim == "" and #it.builders == 0, "and nothing is written")
  -- The review claim runs through the same gate: hand the build over
  -- as a real session, then offer the review to a flag-shaped one.
  assert(verbs.cmd_take(s, leaf, "builder-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "builder-a", 7, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "--force", 0, false, "") ~= 0,
    "a flag-shaped reviewer is refused")
  assert(check.must(store.load(s, leaf)).reviewer == "",
    "and no reviewer is recorded")
end
test_take_refuses_a_flag_shaped_session()

-- An unplaced item is refused at take: placement is ordinal, and an
-- item nothing has been compared against cannot be queued honestly.
local function test_take_refuses_unplaced_work()
  local s = init_state_repo("unplaced")
  local capture = file_item(s, "an unplaced root", "")
  local kid = file_item(s, "its child", capture)
  give_spec(s, kid)
  assert(verbs.cmd_take(s, kid, "session-a", 0, false, "") ~= 0,
    "work under an unplaced root has no position")
end
test_take_refuses_unplaced_work()

-- A blocked item is refused at take, and the refusal names the
-- blocker so the session knows what to finish first.
local function test_take_refuses_a_blocked_item()
  local s = init_state_repo("blocked")
  local goal, leaf = root_with_leaf(s)
  local blocker = file_item(s, "lands first", goal)
  give_spec(s, leaf)
  assert(graph.cmd_block(s, leaf, blocker, false, "the API lands there") == 0)
  local code = verbs.cmd_take(s, leaf, "session-a", 0, false, "")
  assert(code ~= 0, "an open blocker refuses the take")
  assert(verbs.cmd_done(s, blocker, "completed", false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0,
    "a closed blocker no longer binds")
end
test_take_refuses_a_blocked_item()

-- The doing bound binds NEW takes only: at the limit a take of todo
-- work is refused, while a re-take of in-flight work is not.
local function test_the_bound_refuses_new_takes_not_retakes()
  local s = init_state_repo("bound")
  local goal, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  for k = 2, flow.DOING_LIMIT do
    local id = file_item(s, ("slice %d"):format(k), goal)
    give_spec(s, id)
    assert(verbs.cmd_take(s, id, ("wake-%d"):format(k), 0, false, "") == 0)
  end
  local extra = file_item(s, "one too many", goal)
  give_spec(s, extra)
  assert(verbs.cmd_take(s, extra, "session-b", 0, false, "") ~= 0,
    "doing is at its bound: the new take queues")
  assert(check.must(store.load(s, extra)).claim == "", "and stays todo")
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0,
    "re-taking your own in-flight work adds nothing and is admitted")
end
test_the_bound_refuses_new_takes_not_retakes()

-- A claim is a lease: a live foreign claim refuses a take without
-- force, and the builder's own re-take is free.
local function test_a_live_foreign_claim_holds()
  local s = init_state_repo("lease")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-b", 0, false, "") ~= 0,
    "a live claim is another builder mid loop")
  assert(check.must(store.load(s, leaf)).claim == "session-a", "and holds")
  assert(verbs.cmd_take(s, leaf, "session-b", 0, true,
      "the builder's session died mid-slice") == 0,
    "a takeover says so with --force --why")
  local taken = check.must(store.load(s, leaf))
  assert(taken.claim == "session-b", "the claim moved")
  assert(#taken.builders == 2, "and both holders are on the record")
end
test_a_live_foreign_claim_holds()

-- `take --pr` is the handover: the PR rides the claim, and a standing
-- send-back clears because the new push is a new head to judge. On a
-- local-only board the GitHub gate stands down.
local function test_take_pr_records_the_handover()
  local s = init_state_repo("handover")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 4242, false, "") == 0)
  local got = check.must(store.load(s, leaf))
  assert(got.pr == 4242, "the PR rides the handover: " .. got.pr)
  assert(got.claim == "session-a", "the claim survives it")
  assert(flow.substate(got) == "review", "and the item awaits a verdict")
end
test_take_pr_records_the_handover()

-- One PR couples one item's verdict: recording a number another OPEN
-- item already carries is refused, naming the holder, and nothing is
-- written to the item that tried.
local function test_take_pr_refuses_a_number_another_item_holds()
  local s = init_state_repo("pr-collision")
  local _, a = root_with_leaf(s)
  local _, b = root_with_leaf(s)
  give_spec(s, a)
  give_spec(s, b)
  assert(verbs.cmd_take(s, a, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, b, "session-b", 0, false, "") == 0)
  assert(verbs.cmd_take(s, a, "session-a", 7, false, "") == 0)
  assert(verbs.cmd_take(s, b, "session-b", 7, false, "") ~= 0,
    "PR #7 is already A's -- one PR, one item")
  assert(check.must(store.load(s, b)).pr == 0, "and nothing is written")
end
test_take_pr_refuses_a_number_another_item_holds()

-- The same item re-recording its own number stays the existing no-op:
-- the collision check never fires against itself.
local function test_take_pr_rerecord_of_its_own_number_stays_a_noop()
  local s = init_state_repo("pr-self-noop")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 7, false, "") == 0)
  local before = commits(s)
  assert(verbs.cmd_take(s, leaf, "session-a", 7, false, "") == 0,
    "re-recording its own number is a no-op")
  assert(commits(s) == before, "nothing new to commit")
end
test_take_pr_rerecord_of_its_own_number_stays_a_noop()

-- A DONE item's PR is spent: it does not block another item from
-- recording the same number.
local function test_take_pr_ignores_a_done_items_number()
  local s = init_state_repo("pr-done-spent")
  local _, a = root_with_leaf(s)
  local _, b = root_with_leaf(s)
  give_spec(s, a)
  give_spec(s, b)
  assert(verbs.cmd_take(s, a, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, a, "session-a", 7, false, "") == 0)
  assert(verbs.cmd_done(s, a, "completed", true,
      "closing for the fixture") == 0)
  assert(verbs.cmd_take(s, b, "session-b", 0, false, "") == 0)
  assert(verbs.cmd_take(s, b, "session-b", 7, false, "") == 0,
    "A's PR is spent once A is done")
  assert(check.must(store.load(s, b)).pr == 7, "and B's records it")
end
test_take_pr_ignores_a_done_items_number()

-- --force --why overrides the collision, same as every other refusal
-- here, and the reason rides the commit subject.
local function test_take_pr_collision_forced_lands_with_the_suffix()
  local s = init_state_repo("pr-collision-forced")
  local _, a = root_with_leaf(s)
  local _, b = root_with_leaf(s)
  give_spec(s, a)
  give_spec(s, b)
  assert(verbs.cmd_take(s, a, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, b, "session-b", 0, false, "") == 0)
  assert(verbs.cmd_take(s, a, "session-a", 7, false, "") == 0)
  assert(verbs.cmd_take(s, b, "session-b", 7, true,
      "repairing a duplicate PR record") == 0,
    "--force --why overrides the collision")
  assert(check.must(store.load(s, b)).pr == 7, "the number lands")
  local events = check.must(publish.history(s, b))
  assert(events[1].subject:find("forced: repairing a duplicate", 1, true),
    "the reason rides the commit: " .. events[1].subject)
end
test_take_pr_collision_forced_lands_with_the_suffix()

-- A drop names its reason, clears every lock together, and is never
-- refused for flow — leftward motion is the system correcting itself.
local function test_drop_clears_the_locks_and_names_the_reason()
  local s = init_state_repo("drop")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 77, false, "") == 0)
  assert(verbs.cmd_drop(s, leaf, "session-a", "", false) ~= 0,
    "a drop with no reason named is refused")
  assert(verbs.cmd_drop(s, leaf, "session-a",
      "session out of budget mid-slice", false) == 0)
  local dropped = check.must(store.load(s, leaf))
  assert(dropped.claim == "" and dropped.pr == 0 and dropped.verdict == "",
    "the claim, the PR and any verdict clear together")
  assert(not flow.is_doing(dropped), "the item is todo again")
  local events = check.must(publish.history(s, leaf))
  assert(events[1].subject:find("out of budget", 1, true),
    "the reason is in the log: " .. events[1].subject)
  assert(verbs.cmd_drop(s, leaf, "session-a", "again", false) ~= 0,
    "dropping what is not in flight is a typo, not a mutation")
end
test_drop_clears_the_locks_and_names_the_reason()

-- A drop returns the lease and touches nothing else: an edge wired
-- mid-build (the block-first exit for an item that cannot proceed)
-- survives the drop, so the released item waits on its question
-- instead of re-entering the pull queue.
local function test_drop_leaves_blockers_standing()
  local s = init_state_repo("drop-blocked")
  local goal, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  local question = file_item(s, "which premise still holds?", goal)
  assert(graph.cmd_block(s, leaf, question, false,
      "the measured premise no longer reproduces") == 0)
  assert(verbs.cmd_drop(s, leaf, "session-a",
      "blocked on the question", false) == 0)
  local dropped = check.must(store.load(s, leaf))
  assert(dropped.claim == "", "the lease returned")
  assert(#dropped.blocked_by == 1 and dropped.blocked_by[1] == question,
    "the blocker edge survives the drop")
  local index = flow.by_id(check.must(store.list(s)))
  assert(flow.is_blocked(dropped, index),
    "the released item waits on its open question")
end
test_drop_leaves_blockers_standing()

-- Another session's live claim refuses a drop without force: the
-- builder may be mid loop on a machine the board cannot see.
local function test_a_foreign_drop_needs_force()
  local s = init_state_repo("abandon")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_drop(s, leaf, "session-b", "looks dead to me",
      false) ~= 0,
    "another session cannot silently abandon a live claim")
  assert(check.must(store.load(s, leaf)).claim == "session-a", "it holds")
  assert(verbs.cmd_drop(s, leaf, "session-b",
      "the builder's session died mid-slice", true) == 0,
    "a forced abandon with the gap named goes through")
end
test_a_foreign_drop_needs_force()

-- `done` under an unjudged PR is refused: the diff still exists on
-- GitHub, and ending the item makes it vanish from the board. Claimed
-- no-PR work is evidence mid-review the same way — an item nobody
-- ever claimed carries no such claim of success, and ends freely, but
-- a claimant's research slice needs its accept the same as a diff
-- does; `--force --why` remains the repair for ending one nothing
-- will ever review (an obsolete slice, a duplicate).
local function test_done_guards_an_unjudged_pr()
  local s = init_state_repo("done-guard")
  local goal, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 99, false, "") == 0)
  assert(verbs.cmd_done(s, leaf, "completed", false, "") ~= 0,
    "an unjudged PR holds the item open")
  assert(verbs.cmd_done(s, leaf, "completed", true,
      "the PR was closed by hand") == 0,
    "--force --why is the repair path")
  local other = file_item(s, "a research slice", goal)
  give_spec(s, other)
  assert(verbs.cmd_take(s, other, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_done(s, other, "completed", false, "") ~= 0,
    "claimed no-PR work with no accept holds the item open too")
  assert(vrd.cmd_verdict(s, other, "accept", 0, "", "reviewer-a") == 0,
    "an evidence-only item takes a verdict too — no --head needed")
  assert(verbs.cmd_done(s, other, "completed", false, "") == 0,
    "an accept clears the way")
  local ended = check.must(store.load(s, other))
  assert(ended.claim == "", "and done clears the claim")
  local dup = file_item(s, "a duplicate of the slice above", goal)
  give_spec(s, dup)
  assert(verbs.cmd_take(s, dup, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_done(s, dup, "completed", true,
      "duplicate of the research slice above") == 0,
    "--force --why still ends an item nothing will ever review")
end
test_done_guards_an_unjudged_pr()

-- `drop` clears the live claim but never touches `builders` — the
-- append-only record of every session that ever held it — so the
-- PR-less done gate above must key on that history, not the live
-- claim. Keying on the live claim let take -> drop -> done slip a
-- worked research item past review with no verdict and no --force:
-- the exact bypass this test pins shut.
local function test_done_guards_a_dropped_items_worked_history()
  local s = init_state_repo("drop-then-done")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_drop(s, leaf, "session-a",
      "pausing to rethink the approach", false) == 0)
  local dropped = check.must(store.load(s, leaf))
  assert(dropped.claim == "" and #dropped.builders == 1,
    "the claim clears but the builders record survives the drop")
  assert(verbs.cmd_done(s, leaf, "completed", false, "") ~= 0,
    "a dropped item with worked history still owes a verdict")
  assert(verbs.cmd_done(s, leaf, "completed", true,
      "abandoning this line of research") == 0,
    "--force --why remains the repair path")
  local ended = check.must(store.load(s, leaf))
  assert(ended.claim == "", "and done clears the claim")
end
test_done_guards_a_dropped_items_worked_history()

-- Closing the last child makes the container workable again by
-- derivation — nothing is written to it, and the verdict line says
-- what to do with it.
local function test_done_says_when_a_container_is_workable_again()
  local s = init_state_repo("return")
  local _, leaf = root_with_leaf(s)
  local kid = file_item(s, "only child", leaf)
  local before = commits(s)
  assert(verbs.cmd_done(s, kid, "completed", false, "") == 0)
  assert(commits(s) == before + 1, "the close is one commit")
  local all = check.must(store.list(s))
  local parent = flow.by_id(all)[leaf]
  assert(flow.role(parent, all) == "work",
    "its last child closed, so the container is workable by derivation")
  assert(#flow.graph_problems(all) == 0,
    "and nothing is left off the board: "
    .. table.concat(flow.graph_problems(all), "; "))
end
test_done_says_when_a_container_is_workable_again()

-- --force is for repair, and a repair the log cannot explain is
-- indistinguishable from ordinary flow.
local function test_force_states_its_reason_and_the_log_keeps_it()
  local s = init_state_repo("why")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, true, "") ~= 0,
    "a bare --force is refused")
  assert(check.must(store.load(s, leaf)).claim == "", "and changes nothing")
  assert(verbs.cmd_take(s, leaf, "session-a", 0, true,
      "repairing a claim the importer mangled") == 0)
  local events = check.must(publish.history(s, leaf))
  assert(events[1].subject:find("forced: repairing a claim", 1, true),
    "the reason rides the commit: " .. events[1].subject)
end
test_force_states_its_reason_and_the_log_keeps_it()

-- A take after a lost push race is refused with LOST_RACE and lands
-- on the re-run against the merged state, leaving the checkout clean.
local function test_a_take_survives_a_lost_race()
  local a, b = init_shared("take-race")
  local goal, leaf = root_with_leaf(a)
  give_spec(a, leaf)
  assert(publish.sync(b))
  assert(graph.cmd_new(b, "theirs", goal, nil, "") == 0)
  assert(verbs.cmd_take(a, leaf, "session-a", 0, false, "") ~= 0,
    "the stale run is refused, not replayed")
  assert(verbs.cmd_take(a, leaf, "session-a", 0, false, "") == 0,
    "the re-run lands against the merged board")
  local r = check.must(child.run({"git", "status", "--porcelain"},
      {cwd = a.root}))
  assert((r.stdout:gsub("%s+$", "")) == "",
    "the mutation leaves no stray change: " .. r.stdout)
end
test_a_take_survives_a_lost_race()

-- sync rebases and then asks about lane health; a local-only checkout
-- has no origin, so lane health comes back unknown rather than red,
-- and sync itself still succeeds — the same shape a token-less or
-- offline session sees. `_work.lanes_test` drives `observe`/`record`/
-- `mint` directly; this pins that `cmd_sync` reaches them at all.
local function test_sync_asks_about_lanes_and_survives_not_knowing()
  local s = init_state_repo("sync-lanes")
  assert(verbs.cmd_sync(s) == 0, "an unknown lane state does not fail sync")
end
test_sync_asks_about_lanes_and_survives_not_knowing()
