#!/usr/bin/env cosmic
-- The review claim: pushed before the reading, consumed by the
-- verdict, cleared by any move out of check, and honored by the
-- review ordering. The scratch board harness is `_work.fixture`.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local health = require("_work.health")
local rev = require("_work.gitreview")
local store = require("_work.store")
local verbs = require("_work.gitverbs")
local vrd = require("_work.gitverdict")

local init_state_repo = fixture.init_state_repo
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

--- Walk a fresh leaf into check: the phases in order, built by
--- `builder`, handed over carrying PR 7.
local function into_check(s: store.Store, leaf: string, builder: string)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", builder, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", builder, 7, false, "") == 0)
end

-- The claim is first-writer-wins: a second session is refused while
-- the first's claim is live, told who holds it, and a re-claim by the
-- holder is an idempotent yes.
local function test_a_live_claim_excludes_a_second_reviewer()
  local s = init_state_repo("review-claim")
  local _, leaf = root_with_leaf(s)
  into_check(s, leaf, "builder-a")
  assert(rev.cmd_review(s, leaf, "reviewer-b", false, "") == 0,
    "the first reviewer claims")
  check.equal(check.must(store.load(s, leaf)).reviewer, "reviewer-b")
  assert(rev.cmd_review(s, leaf, "reviewer-c", false, "") ~= 0,
    "a second session is refused while the claim is live")
  check.equal(check.must(store.load(s, leaf)).reviewer, "reviewer-b",
    "and the claim did not move")
  assert(rev.cmd_review(s, leaf, "reviewer-b", false, "") == 0,
    "the holder re-claiming is a yes, not a collision")
end
test_a_live_claim_excludes_a_second_reviewer()

-- A live claim is taken over only on the record: --force needs --why,
-- and with both the claim moves.
local function test_takeover_goes_through_force_why()
  local s = init_state_repo("review-force")
  local _, leaf = root_with_leaf(s)
  into_check(s, leaf, "builder-a")
  assert(rev.cmd_review(s, leaf, "reviewer-b", false, "") == 0)
  assert(rev.cmd_review(s, leaf, "reviewer-c", true, "") ~= 0,
    "--force without --why is refused")
  assert(rev.cmd_review(s, leaf, "reviewer-c", true, "b went dark") == 0,
    "with --why the takeover lands")
  check.equal(check.must(store.load(s, leaf)).reviewer, "reviewer-c")
end
test_takeover_goes_through_force_why()

-- The claim is mutual exclusion and nothing more: the builder asks
-- for it like anyone else and gets it, because review isolation is
-- the review procedure's job rather than an identity test here.
local function test_the_builder_may_claim_the_review()
  local s = init_state_repo("review-builder")
  local _, leaf = root_with_leaf(s)
  into_check(s, leaf, "builder-a")
  assert(rev.cmd_review(s, leaf, "builder-a", false, "") == 0,
    "the builder may claim the review")
  check.equal(check.must(store.load(s, leaf)).reviewer, "builder-a",
    "and the claim is stamped")
end
test_the_builder_may_claim_the_review()

-- A claim by nobody excludes nobody, and only check has reviews to
-- claim.
local function test_unnamed_sessions_and_other_phases_are_refused()
  local s = init_state_repo("review-shape")
  local _, leaf = root_with_leaf(s)
  assert(rev.cmd_review(s, leaf, "reviewer-b", false, "") ~= 0,
    "a backlog item has no review to claim")
  into_check(s, leaf, "builder-a")
  assert(rev.cmd_review(s, leaf, "", false, "") ~= 0,
    "an unnamed session cannot claim")
end
test_unnamed_sessions_and_other_phases_are_refused()

-- The verdict consumes the claim — from the claimant or any other
-- non-builder, because the claim is mutual exclusion, not authority.
local function test_a_verdict_consumes_the_claim()
  local s = init_state_repo("review-verdict")
  local _, leaf = root_with_leaf(s)
  into_check(s, leaf, "builder-a")
  assert(rev.cmd_review(s, leaf, "reviewer-b", false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 7, "abc1234",
      "none: test", "reviewer-c") == 0,
    "a non-claimant's verdict still stands")
  local it = check.must(store.load(s, leaf))
  check.equal(it.reviewer, "", "the claim was consumed")
  check.equal(it.phase, "do", "and the verdict's move followed")
end
test_a_verdict_consumes_the_claim()

-- Any move out of check ends the reading, so the claim never follows
-- the item somewhere no verdict can consume it.
local function test_leaving_check_clears_the_claim()
  local s = init_state_repo("review-move")
  local _, leaf = root_with_leaf(s)
  into_check(s, leaf, "builder-a")
  assert(rev.cmd_review(s, leaf, "reviewer-b", false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "builder-a", 0, true,
      "rework without a verdict, for the test") == 0)
  check.equal(check.must(store.load(s, leaf)).reviewer, "",
    "the claim went with the phase")
end
test_leaving_check_clears_the_claim()

-- The review lease is the short one, and staleness is a property of
-- the ages the caller reads — pinned here at the boundary values.
local function test_the_review_lease_is_short_and_exact()
  local i = {id = "x", reviewer = "reviewer-b"}
  local at = health.REVIEW_LEASE_S
  assert(not health.is_review_stale(i, {x = at}),
    "at the lease is not past it")
  assert(health.is_review_stale(i, {x = at + 1}), "past it is stale")
  assert(not health.is_review_stale(i, {}), "unknown age never reads stale")
  assert(not health.is_review_stale({id = "x", reviewer = ""}, {x = at + 1}),
    "no claim, nothing to be stale")
  assert(health.REVIEW_LEASE_S < health.LEASE_S,
    "a review locks minutes of work; a build locks hours")
end
test_the_review_lease_is_short_and_exact()
