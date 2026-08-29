#!/usr/bin/env cosmic
-- The review claim: pushed before the reading, consumed by the
-- verdict, cleared by a drop, and honored by the review ordering.
-- The scratch board harness is `_work.fixture`.

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

--- A fresh leaf taken by `builder` and handed over carrying PR 7.
local function handed_over(s: store.Store, leaf: string, builder: string)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, builder, 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, builder, 7, false, "") == 0)
end

-- The claim is first-writer-wins: a second session is refused while
-- the first's claim is live, told who holds it, and a re-claim by the
-- holder is an idempotent yes.
local function test_a_live_claim_excludes_a_second_reviewer()
  local s = init_state_repo("review-claim")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
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
  handed_over(s, leaf, "builder-a")
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
  handed_over(s, leaf, "builder-a")
  assert(rev.cmd_review(s, leaf, "builder-a", false, "") == 0,
    "the builder may claim the review")
  check.equal(check.must(store.load(s, leaf)).reviewer, "builder-a",
    "and the claim is stamped")
end
test_the_builder_may_claim_the_review()

-- A claim by nobody excludes nobody, and only a PR awaiting a verdict
-- has a review to claim.
local function test_unnamed_sessions_and_unreviewable_items_are_refused()
  local s = init_state_repo("review-shape")
  local _, leaf = root_with_leaf(s)
  assert(rev.cmd_review(s, leaf, "reviewer-b", false, "") ~= 0,
    "a todo item has no diff to claim")
  handed_over(s, leaf, "builder-a")
  assert(rev.cmd_review(s, leaf, "", false, "") ~= 0,
    "an unnamed session cannot claim")
  assert(vrd.cmd_verdict(s, leaf, "accept", 7, "abc1234") == 0)
  assert(rev.cmd_review(s, leaf, "reviewer-b", false, "") ~= 0,
    "a standing verdict leaves nothing awaiting review")
end
test_unnamed_sessions_and_unreviewable_items_are_refused()

-- The verdict consumes the claim — from the claimant or from any
-- other session, because the claim is mutual exclusion, not authority.
local function test_a_verdict_consumes_the_claim()
  local s = init_state_repo("review-verdict")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  assert(rev.cmd_review(s, leaf, "reviewer-b", false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 7, "abc1234",
      "reviewer-c") == 0,
    "a non-claimant's verdict still stands")
  local it = check.must(store.load(s, leaf))
  check.equal(it.reviewer, "", "the claim was consumed")
  check.equal(it.verdict, "request changes", "and the send-back stands")
end
test_a_verdict_consumes_the_claim()

-- A drop ends the reading with everything else: the claim never
-- outlives the diff it locked.
local function test_a_drop_clears_the_review_claim()
  local s = init_state_repo("review-drop")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  assert(rev.cmd_review(s, leaf, "reviewer-b", false, "") == 0)
  assert(verbs.cmd_drop(s, leaf, "builder-a",
      "the spec cannot answer the encoding question", false) == 0)
  check.equal(check.must(store.load(s, leaf)).reviewer, "",
    "the claim went with the drop")
end
test_a_drop_clears_the_review_claim()

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
