#!/usr/bin/env cosmic
-- The verdict verb: what it may judge (a PR with no standing verdict),
-- the head it refuses to judge twice, and the effect each kind has on
-- the item's derived state. The scratch board harness is
-- `_work.fixture`.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local flow = require("_work.flow")
local gitspec = require("_work.gitspec")
local fs = require("cosmic.fs")
local publish = require("_work.publish")
local spec = require("_work.spec")
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

--- Run vrd.cmd_verdict and capture exactly what it prints via print()
--- -- the verdict line every verb writes through gate.verdict_line --
--- the same swap-and-restore pattern _tool/example.tl,
--- _tool/benchmark.tl and _eval/score_test.tl use to pin a CLI's exact
--- console output, without paying for a real subprocess spawn.
--- @param s store.Store The store
--- @param id string The item under verdict
--- @param kind string accept | request changes | reject
--- @param pr integer The PR the verdict judges, 0 to use the item's own
--- @param head string The head commit the verdict judges
--- @param session string | nil The reviewing session; rides in the subject
--- @param force boolean | nil Record over the distance guard — repair only
--- @param why string | nil Why --force was needed
--- @return integer cmd_verdict's exit code
--- @return string Every print()'d line, newline-joined
local function verdict_and_capture(s: store.Store, id: string, kind: string,
    pr: integer, head: string, session?: string, force?: boolean,
    why?: string): integer, string
  local old_print = _G.print
  local lines: {string} = {}
  _G.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local ok, result = pcall(vrd.cmd_verdict, s, id, kind, pr, head, session,
    force, why)
  _G.print = old_print
  if not ok then
    error(result, 0)
  end
  return result, table.concat(lines, "\n")
end

-- A verdict judges evidence, so a todo item — never claimed, no PR —
-- has nothing for it to say. Once claimed, a PR-less item IS
-- judgeable (its recorded work stands in for a diff); a standing
-- accept is landed, not judged again, whichever way it got there.
local function test_verdict_judges_a_pr_awaiting_one()
  local s = init_state_repo("verdict-guard")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "abc1234") ~= 0,
    "an unclaimed todo item has nothing to judge")
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 0, "abc1234") == 0,
    "a claimed PR-less build is judgeable too")
  assert(flow.substate(check.must(store.load(s, leaf))) == "rework",
    "and the send-back stands the same way")
  assert(verbs.cmd_take(s, leaf, "session-a", 7, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 7, "abc1234") == 0,
    "a PR awaiting a verdict is judged")
  assert(flow.substate(check.must(store.load(s, leaf))) == "accepted",
    "and an accept awaits its merge")
  assert(vrd.cmd_verdict(s, leaf, "accept", 7, "def5678") ~= 0,
    "a standing accept is landed, not re-judged")
end

-- A claimed PR-less item is judged the same way a PR is: recorded
-- (accept and request changes alike), verdict_head stays empty since
-- there is no head to verify, and the pair guard degrades to the spec
-- revision alone — an unchanged spec still has nothing new to say, and
-- a spec rewrite is still a fresh round.
local function test_a_pr_less_item_records_both_verdict_kinds()
  local s = init_state_repo("verdict-pr-less")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "", "reviewer-a") == 0,
    "an evidence-only item takes an accept — no --head needed")
  local it = check.must(store.load(s, leaf))
  assert(it.verdict == "accept", "the accept stands")
  assert(it.verdict_head == "", "no PR, so no head is recorded")
  assert(it.resolution == "", "and the item is not ended here — done finishes it")
end

-- The middle verdict on a PR-less item is the same send-back: the
-- claim and the judged spec revision stand, ready for the claimant to
-- rework in place and record a fresh verdict over the moved spec.
local function test_a_pr_less_pair_guard_degrades_to_the_spec_alone()
  local s = init_state_repo("verdict-pr-less-pair")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 0, "", "reviewer-a") == 0)
  local back = check.must(store.load(s, leaf))
  assert(flow.substate(back) == "rework", "the send-back stands")
  assert(back.claim == "session-a", "with the builder's claim kept")
  assert((back.verdict_spec or "") ~= "",
    "the judged spec revision is on the record")
  local code, printed = verdict_and_capture(s, leaf, "request changes", 0, "",
    "reviewer-a")
  assert(code ~= 0, "the same unchanged spec has nothing new to judge")
  assert(printed:find("was already judged with this spec", 1, true) ~= nil,
    "the printed refusal says what happened: " .. printed)
  -- A spec rewrite alone is a fresh round, exactly as it is for a PR.
  local base = fs.join(fixture.tmpdir, "pr-less-pair-base.md")
  assert(fs.write(base, store.read_spec(s, leaf)))
  local moved = fs.join(fixture.tmpdir, "pr-less-pair-moved.md")
  assert(fs.write(moved, store.read_spec(s, leaf)
      .. "\nMeasured again at rework.\n"))
  assert(gitspec.cmd_spec(s, leaf, moved, base, "session-a") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "", "reviewer-a") == 0,
    "the same (absent) head over a moved spec is judgeable")
end

-- The distance guard binds a PR-less item exactly as it binds a PR:
-- the session that claimed it may not accept it, and only `--force
-- --why` records it anyway — the audited repair path, unchanged.
local function test_a_pr_less_item_keeps_the_distance_guard()
  local s = init_state_repo("verdict-pr-less-distance")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  local code, printed = verdict_and_capture(s, leaf, "accept", 0, "", "session-a")
  assert(code ~= 0, "the session that claimed it may not accept it")
  assert(printed:find("needs a fresh context", 1, true) ~= nil,
    "the printed refusal says what happened: " .. printed)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "", "session-a", true,
      "solo repair, nobody else to review it") == 0,
    "--force --why records it")
end

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
  local code, printed = verdict_and_capture(s, leaf, "request changes", 6, "cafe123")
  assert(code ~= 0, "the same head over the same spec has nothing new to judge")
  assert(printed:find("was already judged with this spec", 1, true) ~= nil,
    "the printed refusal says what happened: " .. printed)
  assert(printed:find("gitboard spec", 1, true) ~= nil,
    "and names the tool for the cure: " .. printed)
  assert(printed:find("record the verdict again", 1, true) ~= nil,
    "and names the way forward: " .. printed)
  -- A spec rewrite alone is a fresh round: the diff stood still and
  -- the other half of the evidence moved.
  local base = fs.join(fixture.tmpdir, "pair-base.md")
  assert(fs.write(base, store.read_spec(s, leaf)))
  local moved = fs.join(fixture.tmpdir, "pair-moved.md")
  assert(fs.write(moved, store.read_spec(s, leaf)
      .. "\nMeasured again at rework.\n"))
  assert(gitspec.cmd_spec(s, leaf, moved, base, "session-a") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 6, "cafe123") == 0,
    "the same head over a moved spec is judgeable")
end

-- A cure can land OUTSIDE the PR — head and spec both unmoved — so the
-- refusal for an already-judged pair names the way forward instead of
-- dead-ending: extend the spec with a Rework note, then judge again.
local function test_already_judged_refusal_names_the_way_forward()
  local msg = vrd.already_judged_refusal("abcdef1234", "cafe1230000")
  assert(msg:find("was already judged with this spec", 1, true) ~= nil,
    "still says what happened: " .. msg)
  assert(msg:find("gitboard spec", 1, true) ~= nil,
    "names the tool for the cure: " .. msg)
  assert(msg:find("record the verdict again", 1, true) ~= nil,
    "names the way forward: " .. msg)
  assert(msg:find("trips the distance guard", 1, true) ~= nil,
    "warns that a same-session re-record trips the next guard: " .. msg)
  assert(msg:find("--force --why <reason>", 1, true) ~= nil,
    "and names that guard's own repair escape: " .. msg)
end

-- The verb DOES keep an identity distance now: the session named on
-- the claim (`it.builders`, joined by `take`) is refused a verdict on
-- its own item, `--force` alone is not enough, and only `--force
-- --why` records it, the audited repair path.
local function test_the_builder_needs_force_to_verdict_its_own_item()
  local s = init_state_repo("verdict-session")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 11)
  local code, printed = verdict_and_capture(s, leaf, "accept", 11, "abc1234",
    "session-a")
  assert(code ~= 0, "the session that built it may not accept it")
  assert(printed:find("needs a fresh context", 1, true) ~= nil,
    "the printed refusal says what happened: " .. printed)
  assert(printed:find("--force --why", 1, true) ~= nil,
    "and names its own repair escape: " .. printed)
  assert(vrd.cmd_verdict(s, leaf, "accept", 11, "abc1234", "session-a",
      true) ~= 0, "--force without --why is refused")
  assert(vrd.cmd_verdict(s, leaf, "accept", 11, "abc1234", "session-a",
      true, "solo repair, nobody else to review it") == 0,
    "--force --why records it")
  local events = check.must(publish.history(s, leaf))
  assert(events[1].subject:find(" by session-a", 1, true),
    "and the log says who judged: " .. events[1].subject)
  assert(events[1].subject:find("(forced: solo repair", 1, true),
    "and that it was forced: " .. events[1].subject)
end

-- Every board commit is authored as one fixed identity, so the subject
-- is the only place the log can record who judged.
local function test_verdict_subject_names_the_reviewer()
  local s = init_state_repo("verdict-subject")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 12)
  assert(vrd.cmd_verdict(s, leaf, "accept", 12, "abc1234", "review-1") == 0)
  local events = check.must(publish.history(s, leaf))
  assert(events[1].subject:find(" by review-1", 1, true),
    "the reviewer rides in the subject: " .. events[1].subject)
end

-- The PR read is guarded by `publish.has_origin`, the same guard
-- `gate.handover_refusal` uses, so a local-only board never reaches
-- for GitHub — pinned here rather than left as a property nothing
-- asserts.
local function test_accept_without_an_origin_still_stands()
  local s = init_state_repo("verdict-no-origin")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 21)
  assert(not publish.has_origin(s), "the fixture board has no origin")
  assert(vrd.cmd_verdict(s, leaf, "accept", 21, "abc1234", "review-1") == 0,
    "the accept is not refused for want of a PR read")
  local landed = check.must(store.load(s, leaf))
  assert(landed.verdict == "accept", "the accept stands")
  assert(landed.resolution == "", "and the item is not ended here")
end

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

-- The head is verified before anything commits: a malformed --head is
-- refused whether it is too short to be a real sha or is not hex at
-- all, and refusing leaves no trace in the item or the log.
local function test_a_malformed_head_refuses_before_any_commit()
  local s = init_state_repo("verdict-bad-head")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 51)
  local before = check.must(store.load(s, leaf))
  local before_events = check.must(publish.history(s, leaf))

  assert(vrd.cmd_verdict(s, leaf, "accept", 51, "xyz") ~= 0,
    "a non-hex head is refused")
  assert(vrd.cmd_verdict(s, leaf, "accept", 51, "abc123") ~= 0,
    "a 6-character head is too short to be a real sha")

  local after = check.must(store.load(s, leaf))
  assert(after.verdict == before.verdict
    and after.verdict_head == before.verdict_head,
    "neither refusal touched the item")
  local after_events = check.must(publish.history(s, leaf))
  assert(#after_events == #before_events, "neither refusal committed")
end

-- `--session` here is audit, but a flag-shaped name is a mangled
-- argv, not an identity: refused before anything is judged, so it
-- never rides a verdict subject the log would then trust.
local function test_verdict_refuses_a_flag_shaped_session()
  local s = init_state_repo("verdict-flag-session")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 53)
  local before_events = check.must(publish.history(s, leaf))
  assert(vrd.cmd_verdict(s, leaf, "accept", 53, "cafe1234", "--force") ~= 0,
    "a flag-shaped session is refused")
  local it = check.must(store.load(s, leaf))
  assert(it.verdict == "" and it.verdict_head == "",
    "the refusal recorded nothing")
  assert(#check.must(publish.history(s, leaf)) == #before_events,
    "and committed nothing")
end

-- A well-formed head over a local-only board (no origin to check it
-- against) lands exactly as it always has: the shape check is a new
-- floor, not a new ceiling.
local function test_a_wellformed_head_still_lands_on_a_local_board()
  local s = init_state_repo("verdict-good-head")
  local _, leaf = root_with_leaf(s)
  handed_over(s, leaf, 52)
  assert(not publish.has_origin(s), "the fixture board has no origin")
  assert(vrd.cmd_verdict(s, leaf, "accept", 52, "cafe1234", "review-1") == 0,
    "a shape-valid head over a local board is judged")
  local it = check.must(store.load(s, leaf))
  assert(it.verdict == "accept", "the accept stands")
  assert(it.verdict_head == "cafe1234",
    "the caller's own head is recorded verbatim with no PR to canonicalize it")
end

-- A research handover is judged as the spec revision it recorded: the
-- verdict lands and stores that revision as `verdict_spec`; a spec
-- that moved between handover and verdict is refused the way a moved
-- PR head is, and a `--pr` offered against the handover is too.
local function test_a_research_handover_refuses_a_spec_that_moved()
  local s = init_state_repo("verdict-result-moved")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "", true) == 0,
    "the research handover")
  local base = fs.join(fixture.tmpdir, "result-base.md")
  assert(fs.write(base, store.read_spec(s, leaf)))
  local moved = fs.join(fixture.tmpdir, "result-moved.md")
  assert(fs.write(moved, store.read_spec(s, leaf) .. "\nOne more finding.\n"))
  assert(gitspec.cmd_spec(s, leaf, moved, base, "session-a") == 0)
  local code, printed = verdict_and_capture(s, leaf, "accept", 0, "",
    "reviewer-a")
  assert(code ~= 0, "a spec that moved past the handover is not what was handed over")
  assert(printed:find("moved since its handover", 1, true) ~= nil,
    "the printed refusal says so: " .. printed)
  assert(printed:find("--result", 1, true) ~= nil,
    "and names the way forward: " .. printed)
  assert(check.must(store.load(s, leaf)).verdict == "", "and nothing was recorded")
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "", true) == 0,
    "handing the moved spec over again")
  local code2, printed2 = verdict_and_capture(s, leaf, "accept", 9, "cafe1234",
    "reviewer-a")
  assert(code2 ~= 0 and printed2:find("not a PR", 1, true) ~= nil,
    "a PR offered against the handover is refused: " .. printed2)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "", "reviewer-a") == 0,
    "the re-handed spec is judged")
  local judged = check.must(store.load(s, leaf))
  assert(judged.verdict == "accept" and judged.verdict_spec == judged.result,
    "the accept records the handed-over revision as the judged spec")
  assert(judged.verdict_head == "", "and no head, there being none")
end

-- A handover's accept outcome names `done`, not a merge it has no PR
-- to await: `done` skips the merge read entirely when `pr` is 0
-- (`gitverbs.cmd_done`), so "awaiting merge" would send the session
-- looking for one that will never exist. A diff's outcome is unchanged.
local function test_a_handovers_accept_outcome_names_done_not_a_merge()
  local s = init_state_repo("verdict-result-outcome")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "", true) == 0)
  local code, printed = verdict_and_capture(s, leaf, "accept", 0, "",
    "reviewer-a")
  assert(code == 0, printed)
  assert(printed:find("accepted — `done ID` ends it", 1, true) ~= nil,
    "names done directly: " .. printed)
  assert(printed:find("merge", 1, true) == nil,
    "and claims no merge: " .. printed)
  local diff_s = init_state_repo("verdict-diff-outcome")
  local _, diff_leaf = root_with_leaf(diff_s)
  handed_over(diff_s, diff_leaf, 7)
  local diff_code, diff_printed = verdict_and_capture(diff_s, diff_leaf,
    "accept", 7, "abc1234", "reviewer-a")
  assert(diff_code == 0, diff_printed)
  assert(diff_printed:find("awaiting merge — land it", 1, true) ~= nil,
    "a diff's outcome is unchanged: " .. diff_printed)
end

-- A reject clears the research handover with the claim, the way it
-- clears a PR: nothing stands, and the item is todo again.
local function test_a_reject_clears_the_research_handover()
  local s = init_state_repo("verdict-result-reject")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "", true) == 0)
  assert(vrd.cmd_verdict(s, leaf, "reject", 0, "", "review-1") == 0)
  local back = check.must(store.load(s, leaf))
  assert(back.result == "" and back.claim == "" and back.verdict == "",
    "nothing stands after a reject")
  assert(not flow.is_doing(back), "the item is todo again")
end

-- A take never re-opens an accept, on either handover: a moved spec
-- over a standing accept records the new revision and the accept
-- stands, exactly as a new PR number over one does — `verdict` still
-- refuses to re-judge it, and `done` lands it. A send-back is the one
-- verdict a fresh handover clears, on both sides alike.
local function test_a_handover_over_an_accept_keeps_the_accept()
  local s = init_state_repo("verdict-result-accept-moved")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "", true) == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "", "reviewer-a") == 0)
  local base = fs.join(fixture.tmpdir, "accept-base.md")
  assert(fs.write(base, store.read_spec(s, leaf)))
  local moved = fs.join(fixture.tmpdir, "accept-moved.md")
  assert(fs.write(moved, store.read_spec(s, leaf) .. "\nA late footnote.\n"))
  assert(gitspec.cmd_spec(s, leaf, moved, base, "session-a") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "", true) == 0,
    "the moved spec is handed over")
  local it = check.must(store.load(s, leaf))
  assert(it.result == spec.revision(store.read_spec(s, leaf)),
    "the new revision is recorded")
  assert(it.verdict == "accept", "and the accept stands")
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "", "reviewer-b") ~= 0,
    "an accept is landed, never re-judged")
  assert(verbs.cmd_done(s, leaf, "completed", false, "") == 0, "done lands it")
  -- The PR side, for the mirror: a new number over an accept keeps it.
  local _, other = root_with_leaf(s)
  handed_over(s, other, 7)
  assert(vrd.cmd_verdict(s, other, "accept", 7, "cafe1234", "reviewer-a") == 0)
  assert(verbs.cmd_take(s, other, "session-a", 8, false, "") == 0)
  assert(check.must(store.load(s, other)).verdict == "accept",
    "the PR handover leaves an accept standing too")
  -- And a send-back is what a fresh handover clears, on both sides.
  local _, third = root_with_leaf(s)
  give_spec(s, third)
  assert(verbs.cmd_take(s, third, "session-b", 0, false, "") == 0)
  assert(verbs.cmd_take(s, third, "session-b", 0, false, "", true) == 0)
  assert(vrd.cmd_verdict(s, third, "request changes", 0, "", "reviewer-a") == 0)
  assert(verbs.cmd_take(s, third, "session-b", 0, false, "", true) == 0,
    "the same spec re-handed over answers the send-back")
  assert(check.must(store.load(s, third)).verdict == "",
    "and the send-back clears, as `--pr N` again clears it")
end
