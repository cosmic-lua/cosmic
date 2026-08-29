#!/usr/bin/env cosmic
-- The review claim, reached through `take` by derivation: an item
-- awaiting a verdict, taken by a session that is not its builder, is
-- the review lock — pushed before the reading, consumed by the
-- verdict, released by the reviewer's own drop. The scratch board
-- harness is `_work.fixture`.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local health = require("_work.health")
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
  assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, false, "") == 0,
    "the first reviewer claims")
  check.equal(check.must(store.load(s, leaf)).reviewer, "reviewer-b")
  assert(verbs.cmd_take(s, leaf, "reviewer-c", 0, false, "") ~= 0,
    "a second session is refused while the claim is live")
  check.equal(check.must(store.load(s, leaf)).reviewer, "reviewer-b",
    "and the claim did not move")
  assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, false, "") == 0,
    "the holder re-claiming is a yes, not a collision")
end
test_a_live_claim_excludes_a_second_reviewer()

-- A live claim is taken over only on the record: --force needs --why,
-- and with both the claim moves.
local function test_takeover_goes_through_force_why()
  local s = init_state_repo("review-force")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "reviewer-c", 0, true, "") ~= 0,
    "--force without --why is refused")
  assert(verbs.cmd_take(s, leaf, "reviewer-c", 0, true, "b went dark") == 0,
    "with --why the takeover lands")
  check.equal(check.must(store.load(s, leaf)).reviewer, "reviewer-c")
end
test_takeover_goes_through_force_why()

-- The derivation keeps the builder OUT of the reviewer slot: their
-- take of their own handed-over item is the build no-op, and the
-- reviewer field stays empty — no session accepts its own work.
local function test_the_builders_take_is_not_a_review_claim()
  local s = init_state_repo("review-builder")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  assert(verbs.cmd_take(s, leaf, "builder-a", 0, false, "") == 0,
    "the builder's take is a yes")
  check.equal(check.must(store.load(s, leaf)).reviewer, "",
    "but it stamps no reviewer")
end
test_the_builders_take_is_not_a_review_claim()

-- A claim by nobody excludes nobody, and a standing verdict leaves no
-- review to claim — a foreign take then is a build takeover, refused
-- while the builder's claim is live.
local function test_unnamed_sessions_and_judged_items()
  local s = init_state_repo("review-shape")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  assert(verbs.cmd_take(s, leaf, "", 0, false, "") ~= 0,
    "an unnamed session cannot claim")
  assert(vrd.cmd_verdict(s, leaf, "accept", 7, "abc1234") == 0)
  assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, false, "") ~= 0,
    "after the verdict a foreign take is a build takeover: refused live")
  check.equal(check.must(store.load(s, leaf)).reviewer, "",
    "and no reviewer was stamped")
end
test_unnamed_sessions_and_judged_items()

-- The verdict consumes the claim — from the claimant or from any
-- other session, because the claim is mutual exclusion, not authority.
local function test_a_verdict_consumes_the_claim()
  local s = init_state_repo("review-verdict")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 7, "abc1234",
      "reviewer-c") == 0,
    "a non-claimant's verdict still stands")
  local it = check.must(store.load(s, leaf))
  check.equal(it.reviewer, "", "the claim was consumed")
  check.equal(it.verdict, "request changes", "and the send-back stands")
end
test_a_verdict_consumes_the_claim()

-- The reviewer's own drop releases the review alone: the diff still
-- awaits its verdict, and the builder's claim is not the reviewer's
-- to bounce. The builder's drop clears everything, review included.
local function test_drop_releases_by_derivation()
  local s = init_state_repo("review-drop")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, false, "") == 0)
  assert(verbs.cmd_drop(s, leaf, "reviewer-b",
      "cannot finish this reading", false) == 0)
  local it = check.must(store.load(s, leaf))
  check.equal(it.reviewer, "", "the review is anyone's again")
  check.equal(it.claim, "builder-a", "the build claim stands")
  check.equal(it.pr, 7, "and the PR still awaits its verdict")
  assert(verbs.cmd_take(s, leaf, "reviewer-c", 0, false, "") == 0)
  assert(verbs.cmd_drop(s, leaf, "builder-a",
      "the spec cannot answer the encoding question", false) == 0)
  local bounced = check.must(store.load(s, leaf))
  check.equal(bounced.reviewer, "", "the builder's drop clears the review")
  check.equal(bounced.claim, "", "and the claim")
  check.equal(bounced.pr, 0, "and the PR: the item is todo again")
end
test_drop_releases_by_derivation()

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
