#!/usr/bin/env cosmic
-- The review claim, reached through `take` by derivation: an item
-- awaiting a verdict, taken by a session that is not its builder, is
-- the review lock — pushed before the reading, consumed by the
-- verdict, released by the reviewer's own drop. The scratch board
-- harness is `_work.fixture`.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local gh = require("_work.gh")
local health = require("_work.health")
local store = require("_work.store")
local verbs = require("_work.gitverbs")
local vrd = require("_work.gitverdict")

local init_state_repo = fixture.init_state_repo
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

--- Stand `gh.head_checks` in for a fixed state for the duration of
--- `f`, restoring the real function even when `f` fails an assertion
--- — a fixture PR in each of the four states, since `_work.gh_test`'s
--- own scope note is that `pull`/`checks` are exercised only against
--- a real repository, never faked at the transport. The head sha and
--- run list riding the returned record are fixed fixture values too —
--- the callers under test read them instead of re-fetching, so a stub
--- with nothing there would starve them. A nil `state` stands in for
--- no GitHub reach, so the stub itself returns nil then, not a record.
--- @param state string | nil The state `head_checks` reports
--- @param f function(): boolean The test body; returns true when done
local function with_ci_state(state: string | nil, f: function(): boolean)
  local real = gh.head_checks
  gh.head_checks = function(_s: store.Store, _pr: integer, _repo: string | nil):
    gh.HeadChecks | nil, string
    if state == nil then
      return nil, "no github reach"
    end
    if state == "running" then
      return {state = state,
        head_sha = "cafef00dfeedfacebeef1234567890abcdef1234",
        runs = {{name = "ci", status = "completed", conclusion = "success"},
          {name = "smoke", status = "in_progress", conclusion = ""}}}, ""
    end
    return {state = state, head_sha = "", runs = {}}, ""
  end
  local ok, err = pcall(f)
  gh.head_checks = real
  if not ok then
    error(err, 0)
  end
end

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

-- A reviewer is not a builder: the review claim is a derived path
-- inside `take`, separate from every claim path, and must never join
-- `builders` — appending there would poison the very record the
-- no-self-review guarantee reads.
local function test_a_review_claim_never_joins_builders()
  local s = init_state_repo("review-not-builder")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, false, "") == 0,
    "reviewer-b claims the review")
  local it = check.must(store.load(s, leaf))
  check.equal(it.reviewer, "reviewer-b", "the review claim lands")
  assert(#it.builders == 1 and it.builders[1] == "builder-a",
    "but the builders record names only the builder: "
    .. table.concat(it.builders, ","))
end

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

-- The distance guard binds inside the derivation itself, with no
-- --force escape: a fresh context cannot be forced into existing. A
-- session named in `builders` never claims the review, even one it no
-- longer holds as its build claim.
local function test_a_named_builder_cannot_review_claim_it()
  local s = init_state_repo("review-distance-builder")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  local it = check.must(store.load(s, leaf))
  it.claim = "reviewer-b"
  it.pr = 5
  it.builders = {"session-a"}
  assert(store.save(s, it,
      "fixture: builder recorded, someone else holds the claim"))
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") ~= 0,
    "the named builder is refused the review claim")
  assert(verbs.cmd_take(s, leaf, "session-a", 0, true, "try anyway") ~= 0,
    "and --force opens no escape here")
  check.equal(check.must(store.load(s, leaf)).reviewer, "",
    "no reviewer was stamped")
end

-- Authorship of the SPEC is the same hole authorship of the diff is:
-- a session named in `speccers` is refused the review claim too.
local function test_a_named_speccer_cannot_review_claim_it()
  local s = init_state_repo("review-distance-speccer")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  local it = check.must(store.load(s, leaf))
  it.claim = "reviewer-b"
  it.pr = 6
  it.speccers = {"session-x"}
  assert(store.save(s, it,
      "fixture: speccer recorded, someone else holds the claim"))
  assert(verbs.cmd_take(s, leaf, "session-x", 0, false, "") ~= 0,
    "the named speccer is refused the review claim")
  check.equal(check.must(store.load(s, leaf)).reviewer, "",
    "no reviewer was stamped")
end

-- Decision, from skills/work/SKILL.md's session-identity section: "a
-- review subagent names itself
-- (`export GITBOARD_SESSION=review-<ID>-<unique>`), because it would
-- otherwise inherit the BUILDER's identity" -- a review subagent's
-- name is ALWAYS distinct from the builder's, so one session name
-- holding a build claim and a review claim at once is not a pattern
-- the skill's design produces. Nothing here manufactures a guard
-- against it either: the one-claim-per-session refusal
-- (`gate.second_claim_refusal`) reasons only about `it.claim`, never
-- `it.reviewer`, so a review claim under a name that also holds a
-- build claim elsewhere stays a yes -- consistent with the skill's
-- text, not a pattern it depends on.
local function test_a_review_claim_coexists_with_a_build_claim()
  local s = init_state_repo("review-and-build")
  local _, a = root_with_leaf(s)
  local _, b = root_with_leaf(s)
  give_spec(s, a)
  handed_over(s, b, "builder-b")
  -- The review comes first by rule, not by choice: while b's verdict
  -- is unclaimed, a's pull is review debt and `take` refuses it.
  assert(verbs.cmd_take(s, b, "session-a", 0, false, "") == 0,
    "session-a claims b's review")
  assert(verbs.cmd_take(s, a, "session-a", 0, false, "") == 0,
    "and, under the same name, claims a's build too")
  check.equal(check.must(store.load(s, b)).reviewer, "session-a")
  check.equal(check.must(store.load(s, a)).claim, "session-a")
end

-- Evidence from PR #1538's rework loop: a bounced item keeps its
-- stale "request changes" verdict field until the fresh verdict
-- lands, so that state must route the same way the empty-verdict
-- state does — a session that is not the recorded builder claims the
-- review, not a second build. The builder's own take still reworks.
local function test_a_bounced_item_still_routes_a_fresh_take_to_review()
  local s = init_state_repo("review-bounced")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 7, "abc1234",
      "reviewer-b") == 0)
  local bounced = check.must(store.load(s, leaf))
  check.equal(bounced.verdict, "request changes")
  check.equal(bounced.reviewer, "", "the claim was consumed by the verdict")
  -- The builder's own re-take, with nothing new to record, is still
  -- the build no-op: the stale verdict does not steer it into review.
  assert(verbs.cmd_take(s, leaf, "builder-a", 0, false, "") == 0,
    "the builder's own take stays on the build path")
  check.equal(check.must(store.load(s, leaf)).reviewer, "",
    "no reviewer was stamped by the builder's own take")
  -- A fresh session's take, with no PR to record, is the review claim
  -- again — the stale verdict does not fall through to the build path.
  assert(verbs.cmd_take(s, leaf, "reviewer-c", 0, false, "") == 0,
    "a fresh session claims the review, not a second build")
  local claimed = check.must(store.load(s, leaf))
  check.equal(claimed.reviewer, "reviewer-c")
  check.equal(claimed.claim, "builder-a", "the build claim is untouched")
  assert(#claimed.builders == 1 and claimed.builders[1] == "builder-a",
    "the reviewer never joins builders: "
    .. table.concat(claimed.builders, ","))
  -- The original builder's rework — a new head to judge — clears the
  -- stale verdict and still lands on the build path, not the review.
  assert(verbs.cmd_drop(s, leaf, "reviewer-c",
      "handing back for the rework", false) == 0)
  assert(verbs.cmd_take(s, leaf, "builder-a", 8, false, "") == 0,
    "the builder's rework is the build path, not a review claim")
  local reworked = check.must(store.load(s, leaf))
  check.equal(reworked.pr, 8, "the new head lands")
  check.equal(reworked.verdict, "", "the stale verdict clears on the new head")
  check.equal(reworked.reviewer, "", "no reviewer was stamped")
end

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

-- PR #1657's evidence: a review claimed while `smoke`/`repro` were
-- still `in_progress` burned a reviewer session before anything had
-- settled. Green, red and a repo with no checks at all still claim —
-- a decided fact (or none) is a reviewer's to read; only a run still
-- going is refused, and only without `--force`.
local function test_ci_running_refuses_the_review_claim()
  for _, case in ipairs({
      {state = "green", ok = true},
      {state = "none", ok = true},
      {state = "red", ok = true},
      {state = "running", ok = false},
    }) do
    local s = init_state_repo("review-ci-" .. case.state)
    local _, leaf = root_with_leaf(s)
    handed_over(s, leaf, "builder-a")
    with_ci_state(case.state, function(): boolean
        local code = verbs.cmd_take(s, leaf, "reviewer-" .. case.state, 0,
          false, "")
        if case.ok then
          assert(code == 0, ("state %s should claim the review: %d"):format(
              case.state, code))
          check.equal(check.must(store.load(s, leaf)).reviewer,
            "reviewer-" .. case.state)
        else
          assert(code ~= 0, ("state %s should refuse the review claim"):format(
              case.state))
          check.equal(check.must(store.load(s, leaf)).reviewer, "",
            "nothing was stamped")
        end
        return true
      end)
  end
end

-- --force is the escape for a reviewer who has a reason to claim
-- anyway; the record says so.
local function test_ci_running_force_claims_the_review_anyway()
  local s = init_state_repo("review-ci-force")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  with_ci_state("running", function(): boolean
      assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, false, "") ~= 0,
        "refused while CI runs")
      assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, true,
          "know it's fine") == 0, "--force claims anyway")
      return true
    end)
  check.equal(check.must(store.load(s, leaf)).reviewer, "reviewer-b")
end

-- A store with no GitHub reach — no origin here — reads `head_checks`
-- as nil, never as "running", so the review claim is unaffected: the
-- rest of this file's fixtures (`init_state_repo`, no origin) prove
-- this on every ordinary run; this test just says so directly.
local function test_no_github_reach_does_not_refuse_the_claim()
  local s = init_state_repo("review-ci-offline")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, "builder-a")
  assert(verbs.cmd_take(s, leaf, "reviewer-b", 0, false, "") == 0,
    "no origin to read CI from is not a refusal")
end
