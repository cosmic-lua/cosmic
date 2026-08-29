#!/usr/bin/env cosmic
-- The verdict verb: what it may judge (a PR with no standing verdict),
-- the head it refuses to judge twice, and the effect each kind has on
-- the item's derived state. The scratch board harness is
-- `_work.fixture`.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local flow = require("_work.flow")
local fs = require("cosmic.fs")
local store = require("_work.store")
local verbs = require("_work.gitverbs")
local vrd = require("_work.gitverdict")

local init_state_repo = fixture.init_state_repo
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

--- A leaf taken and handed over: claim plus PR, awaiting a verdict.
local function handed_over(s: store.Store, leaf: string, pr: integer)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", pr, false, "") == 0)
end

-- A verdict judges a diff, so an item with no PR has nothing for it
-- to say — and a standing accept is landed, not judged again.
local function test_verdict_judges_a_pr_awaiting_one()
  local s = init_state_repo("verdict-guard")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "abc1234") ~= 0,
    "a todo item has nothing to judge")
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "abc1234") ~= 0,
    "nor has a build with no PR yet")
  assert(verbs.cmd_take(s, leaf, "session-a", 7, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 7, "abc1234") == 0,
    "a PR awaiting a verdict is judged")
  assert(flow.substate(check.must(store.load(s, leaf))) == "accepted",
    "and an accept awaits its merge")
  assert(vrd.cmd_verdict(s, leaf, "accept", 7, "def5678") ~= 0,
    "a standing accept is landed, not re-judged")
end
test_verdict_judges_a_pr_awaiting_one()

-- A verdict judges a pair — the head and the spec revision it is
-- measured against. The same pair twice says nothing happened in
-- between; a rework that moved EITHER half is a fresh round, because
-- a bounce on the spec's claims is answered by rewriting the spec,
-- which moves no commit.
local function test_a_verdict_refuses_a_pair_it_already_judged()
  local s = init_state_repo("head")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 6)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 6, "cafe123") == 0)
  local back = check.must(store.load(s, leaf))
  assert(flow.substate(back) == "rework", "the send-back stands")
  assert(back.claim == "session-a", "with the builder's claim kept")
  assert((back.verdict_spec or "") ~= "",
    "the judged spec revision is on the record")
  -- The rework hands back: the same PR, and the verdict re-opens.
  assert(verbs.cmd_take(s, leaf, "session-a", 6, false, "") == 0)
  assert(flow.substate(check.must(store.load(s, leaf))) == "review",
    "the handover re-opens the verdict")
  assert(vrd.cmd_verdict(s, leaf, "request changes", 6, "cafe123") ~= 0,
    "the same head over the same spec has nothing new to judge")
  -- A spec rewrite alone is a fresh round: the diff stood still and
  -- the other half of the evidence moved.
  local base = fs.join(fixture.tmpdir, "pair-base.md")
  assert(fs.write(base, store.read_spec(s, leaf)))
  local moved = fs.join(fixture.tmpdir, "pair-moved.md")
  assert(fs.write(moved, store.read_spec(s, leaf)
      .. "\nMeasured again at rework.\n"))
  assert(verbs.cmd_spec(s, leaf, moved, base, "session-a") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 6, "cafe123") == 0,
    "the same head over a moved spec is judgeable")
end
test_a_verdict_refuses_a_pair_it_already_judged()

-- The verb keeps no identity distance: the session named on the claim
-- accepts its own item, because review isolation is carried by the
-- review procedure — a subagent holding the diff and the spec and
-- nothing else — and the log, not the verb, is the audit.
local function test_the_builder_may_verdict_its_own_item()
  local s = init_state_repo("verdict-session")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 11)
  assert(vrd.cmd_verdict(s, leaf, "accept", 11, "abc1234", "session-a") == 0,
    "the session that built it may accept it")
  local events = check.must(store.history(s, leaf))
  assert(events[1].subject:find(" by session-a", 1, true),
    "and the log says who judged: " .. events[1].subject)
end
test_the_builder_may_verdict_its_own_item()

-- Every board commit is authored as one fixed identity, so the subject
-- is the only place the log can record who judged.
local function test_verdict_subject_names_the_reviewer()
  local s = init_state_repo("verdict-subject")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 12)
  assert(vrd.cmd_verdict(s, leaf, "accept", 12, "abc1234", "review-1") == 0)
  local events = check.must(store.history(s, leaf))
  assert(events[1].subject:find(" by review-1", 1, true),
    "the reviewer rides in the subject: " .. events[1].subject)
end
test_verdict_subject_names_the_reviewer()

-- The PR read is guarded by `store.has_origin`, the same guard
-- `gate.handover_refusal` uses, so a local-only board never reaches
-- for GitHub — pinned here rather than left as a property nothing
-- asserts.
local function test_accept_without_an_origin_still_stands()
  local s = init_state_repo("verdict-no-origin")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 21)
  assert(not store.has_origin(s), "the fixture board has no origin")
  assert(vrd.cmd_verdict(s, leaf, "accept", 21, "abc1234", "review-1") == 0,
    "the accept is not refused for want of a PR read")
  local landed = check.must(store.load(s, leaf))
  assert(landed.verdict == "accept", "the accept stands")
  assert(landed.resolution == "", "and the item is not ended here")
end
test_accept_without_an_origin_still_stands()

-- The middle verdict's canonical spelling has a space; the hyphenated
-- and noun spellings must mean the same thing, and a genuinely unknown
-- kind must teach the vocabulary instead of inviting a harsher guess.
local function test_kind_aliases_and_the_teaching_refusal()
  local s = init_state_repo("verdict-alias")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 7)
  assert(vrd.cmd_verdict(s, leaf, "definitely-not-a-kind", 7,
      "abc1234") ~= 0, "an unknown kind is refused")
  assert(vrd.cmd_verdict(s, leaf, "request-changes", 7, "abc1234") == 0,
    "the hyphenated spelling is the middle verdict")
  local it = check.must(store.load(s, leaf))
  assert(it.verdict == "request changes",
    "recorded under the canonical spelling: " .. tostring(it.verdict))
  assert(it.claim == "session-a", "with the builder's claim kept")
end
test_kind_aliases_and_the_teaching_refusal()

-- A reject stands nowhere: claim, PR and verdict clear together, the
-- item is todo again, and what was learned lives in the spec and the
-- closed PR — not in fields the next take would trip over.
local function test_a_reject_returns_the_item_to_todo()
  local s = init_state_repo("verdict-reject")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 31)
  assert(vrd.cmd_verdict(s, leaf, "reject", 31, "abc1234", "review-1") == 0)
  local back = check.must(store.load(s, leaf))
  assert(back.claim == "" and back.pr == 0 and back.verdict == "",
    "nothing stands after a reject")
  assert(not flow.is_doing(back), "the item is todo again")
  assert(#back.builders == 1 and back.builders[1] == "session-a",
    "and the builders record still says who built the rejected round")
end
test_a_reject_returns_the_item_to_todo()

-- The judgment consumes the review claim, whoever held it: the claim
-- is mutual exclusion over the reading, and the reading is over.
local function test_a_verdict_consumes_the_review_claim()
  local s = init_state_repo("verdict-consumes")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 41)
  local it = check.must(store.load(s, leaf))
  it.reviewer = "review-9"
  assert(store.save(s, it, "review claim for the fixture"))
  assert(vrd.cmd_verdict(s, leaf, "request changes", 41, "abc1234") == 0)
  assert(check.must(store.load(s, leaf)).reviewer == "",
    "the verdict consumed the claim")
end
test_a_verdict_consumes_the_review_claim()
