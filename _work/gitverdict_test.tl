#!/usr/bin/env cosmic
-- The verdict verb: the one phase it may end, what a non-accept one
-- files with it, and the evidence — head and spec revision together —
-- it refuses to judge twice. The scratch board harness is
-- `_work.fixture`.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local fs = require("cosmic.fs")
local spec = require("_work.spec")
local store = require("_work.store")
local verbs = require("_work.gitverbs")
local vrd = require("_work.gitverdict")

local init_state_repo = fixture.init_state_repo
local file_item = fixture.file_item
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

-- `check` means "awaiting a planner verdict", so it is the one phase
-- a verdict may end: judging from anywhere else would carry unreviewed
-- work into land past every gate between them.
local function test_verdict_judges_only_what_is_in_check()
  local s = init_state_repo("verdict-phase")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "abc1234", "none: test") ~= 0,
    "a backlog item has not been reviewed")
  assert(check.must(store.load(s, leaf)).phase == "backlog",
    "and did not move")
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 7, "abc1234", "none: test") ~= 0,
    "nor has an item still being worked")
  assert(verbs.cmd_move(s, leaf, "check", nil, 7, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 7, "abc1234", "none: test") == 0,
    "from check it lands")
  assert(check.must(store.load(s, leaf)).phase == "land", "in land")
end
test_verdict_judges_only_what_is_in_check()

-- Every non-accept verdict is evidence about why a presumed-ready item
-- was not, and that evidence is lost unless the countermeasure is
-- filed with it. The trailer takes an item id or a reasoned "none".
local function test_a_non_accept_verdict_files_its_countermeasure()
  local s = init_state_repo("enable")
  local goal, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 5, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 5, "aaa", "") ~= 0,
    "no trailer at all is refused")
  assert(vrd.cmd_verdict(s, leaf, "request changes", 5, "aaa", "none") ~= 0,
    "a reasonless none is not the grammar")
  assert(vrd.cmd_verdict(s, leaf, "request changes", 5, "aaa",
      "3HyArM3A3zHuRxn3VYCvKmUZ7KW") ~= 0,
    "nor is the id of an item that does not exist")
  local counter = file_item(s, "the countermeasure", goal)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 5, "aaa",
      counter:sub(1, 10)) == 0,
    "an unambiguous prefix names the countermeasure, as ids do everywhere")
  assert(check.must(store.load(s, leaf)).enable == counter,
    "and the FULL id is what gets recorded")
  -- An accept has no bounce to explain, so it carries no trailer.
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 5, "bbb", "") == 0,
    "an accept needs none")
  assert(check.must(store.load(s, leaf)).enable == "",
    "and clears the standing one")
end
test_a_non_accept_verdict_files_its_countermeasure()

-- A verdict judges a head AND the spec that head is measured against;
-- judging the same PAIR twice says nothing happened in between, which
-- is not a fresh round. Neither verdict kind is exempt: an accept on
-- evidence that has not moved at all is the rubber stamp the guard
-- exists to refuse.
local function test_a_verdict_refuses_evidence_it_already_judged()
  local s = init_state_repo("head")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 6, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 6, "cafe123",
      "none: this item's own spec was the gap") == 0)
  local judged = check.must(store.load(s, leaf))
  check.equal(judged.verdict_spec, spec.revision(store.read_spec(s, leaf)),
    "the verdict records the spec revision it judged")
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 6, "cafe123",
      "none: still the same gap") ~= 0,
    "the same head over the same spec has nothing new to judge")
  assert(vrd.cmd_verdict(s, leaf, "accept", 6, "cafe123", "") ~= 0,
    "and a change of verdict is not itself a change of evidence")
  assert(vrd.cmd_verdict(s, leaf, "accept", 6, "cafe456", "") == 0,
    "a moved head does")
end
test_a_verdict_refuses_evidence_it_already_judged()

-- A bounce on the Evidence is answered by rewriting the SPEC, which
-- moves no commit: the head stands still by design. Comparing the head
-- alone made that rework unjudgeable, so the pair is what the guard
-- compares and a spec-only round gets its verdict.
local function test_a_spec_only_rework_earns_a_fresh_verdict()
  local s = init_state_repo("spec-rework")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 31, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 31, "5364cc21",
      "none: the spec's Evidence was the gap", "reviewer-one") == 0)
  -- The rework moves the sidecar and nothing else; the PR head is
  -- unchanged, which is what the bounce asked for.
  local base = fs.join(fixture.tmpdir, "spec-rework-base.md")
  local next_spec = fs.join(fixture.tmpdir, "spec-rework-next.md")
  assert(fs.write(base, store.read_spec(s, leaf)))
  assert(fs.write(next_spec,
      fixture.READY_SPEC .. "## Evidence\nRe-ran every command.\n"))
  assert(verbs.cmd_spec(s, leaf, next_spec, base) == 0,
    "the rework rewrites the spec")
  assert(verbs.cmd_move(s, leaf, "check", nil, 31, false, "") == 0)
  local back = check.must(store.load(s, leaf))
  check.equal(back.verdict_head, "5364cc21", "the judged head still stands")
  assert(vrd.cmd_verdict(s, leaf, "accept", 31, "5364cc21", "",
      "reviewer-two") == 0,
    "and the accept on that same head is a fresh round")
  check.equal(check.must(store.load(s, leaf)).phase, "land", "which lands")
end
test_a_spec_only_rework_earns_a_fresh_verdict()

-- A leftward move clears the judgment whole. A revision left beside a
-- cleared head is half a record, and the guard would compare against it.
local function test_a_return_clears_both_halves_of_the_judgment()
  local s = init_state_repo("verdict-cleared")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 41, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 41, "abc1234", "") == 0)
  assert(check.must(store.load(s, leaf)).verdict_spec ~= "",
    "the accept recorded a revision")
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  local returned = check.must(store.load(s, leaf))
  check.equal(returned.verdict_head, "", "the return clears the head")
  check.equal(returned.verdict_spec, "", "and the revision with it")
end
test_a_return_clears_both_halves_of_the_judgment()

-- The verb keeps no identity distance: the session named on the claim
-- and in `builders` accepts its own item and it moves `check -> land`,
-- because review isolation is carried by the review procedure — a
-- subagent holding the diff and the spec and nothing else.
local function test_the_builder_may_verdict_its_own_item()
  local s = init_state_repo("verdict-session")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 11, false, "") == 0)
  local it = check.must(store.load(s, leaf))
  check.equal(it.claim, "session-a", "the claim names the builder")
  assert(#(it.builders or {}) > 0 and it.builders[1] == "session-a",
    "and so does the durable builders record")
  assert(vrd.cmd_verdict(s, leaf, "accept", 11, "abc1234", "", "session-a") == 0,
    "the session that built it may accept it")
  assert(check.must(store.load(s, leaf)).phase == "land", "and it lands")
end
test_the_builder_may_verdict_its_own_item()

-- Every board commit is authored as one fixed identity, so the subject
-- is the only place the log can record who judged — without it,
-- whether an accept came from the item's own builder is unauditable
-- after the fact.
local function test_verdict_subject_names_the_reviewer()
  local s = init_state_repo("verdict-subject")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 12, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 12, "abc1234", "", "session-b") == 0)
  local events = check.must(store.history(s, leaf))
  assert(events[1].subject:find(" by session-b", 1, true),
    "the reviewer rides in the subject: " .. events[1].subject)

  -- An unnamed verdict is still allowed, and says nothing rather than
  -- claiming an empty reviewer. The return clears the claim, so the
  -- rework handover names its builder again.
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", "session-a", 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "def5678", "") == 0)
  local later = check.must(store.history(s, leaf))
  assert(not later[1].subject:find(" by ", 1, true),
    "an unnamed verdict names nobody: " .. later[1].subject)
end
test_verdict_subject_names_the_reviewer()

-- The PR read is guarded by `store.has_origin`, the same guard
-- `gate.handover_refusal` uses, so a local-only board never reaches
-- for GitHub. That guard is what keeps every test above meaning what
-- it meant — all of them run on local-only boards — and it is pinned
-- here rather than left as a property nothing asserts.
local function test_accept_without_an_origin_still_routes_to_land()
  local s = init_state_repo("verdict-no-origin")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 21, false, "") == 0)
  assert(not store.has_origin(s), "the fixture board has no origin")
  assert(vrd.cmd_verdict(s, leaf, "accept", 21, "abc1234", "",
      "session-b") == 0, "the accept is not refused for want of a PR read")
  local landed = check.must(store.load(s, leaf))
  assert(landed.phase == "land",
    "and routes to land as before: " .. tostring(landed.phase))
  assert(landed.resolution == "", "the item is not ended here")
end
test_accept_without_an_origin_still_routes_to_land()

-- The middle verdict's canonical spelling has a space; the hyphenated
-- and noun spellings must mean the same thing, and a genuinely unknown
-- kind must teach the vocabulary instead of inviting a harsher guess.
local function test_kind_aliases_and_the_teaching_refusal()
  local s = init_state_repo("verdict-alias")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 7, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "definitely-not-a-kind", 7, "abc1234",
      "none: test") ~= 0, "an unknown kind is refused")
  assert(vrd.cmd_verdict(s, leaf, "request-changes", 7, "abc1234",
      "none: test") == 0, "the hyphenated spelling is the middle verdict")
  local it = check.must(store.load(s, leaf))
  assert(it.phase == "do", "and it moves to do, not backlog: " .. it.phase)
  assert(it.claim == "session-a", "with the builder's claim kept")
  assert(it.verdict == "request changes",
    "recorded under the canonical spelling: " .. tostring(it.verdict))
end
test_kind_aliases_and_the_teaching_refusal()

-- An accept on an evidence handover authorises no merge, so `land` —
-- whose one remaining act is one — would hold it in a phase `gitboard
-- land` refuses forever. The accept is the whole of its finish.
local function test_accept_on_an_evidence_handover_ends_the_item()
  local s = init_state_repo("verdict-evidence")
  local _, leaf = root_with_leaf(s)
  local path = fs.join(fixture.tmpdir, "verdict-evidence.md")
  assert(fs.write(path, fixture.READY_SPEC .. "## Result\nMeasured, twice.\n"))
  assert(verbs.cmd_spec(s, leaf, path) == 0)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "", true) == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "abc1234", "", "session-b") == 0)
  local it = check.must(store.load(s, leaf))
  assert(it.phase == "", "the accept ended it: " .. tostring(it.phase))
  assert(it.resolution == "completed",
    "and recorded why: " .. tostring(it.resolution))
  assert(it.verdict == "accept", "carrying the verdict that ended it")
end
test_accept_on_an_evidence_handover_ends_the_item()

-- A rework takeover moves the claim to a second builder while the
-- durable `builders` record keeps the first. Neither record withholds
-- the verdict: the first builder accepts the diff they built, and the
-- item leaves `check` on that one accept.
local function test_a_past_builder_may_verdict()
  local s = init_state_repo("verdict-builders")
  local goal, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "builder-one", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 9, false, "") == 0)
  local counter = file_item(s, "the countermeasure", goal)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 9, "aaa1111",
      counter, "reviewer-r") == 0, "the first round bounces the item")
  -- The rework is taken over: the claim moves on, the builders stay.
  assert(verbs.cmd_move(s, leaf, "check", "builder-two", 9, true,
      "takeover: first builder went quiet") == 0)
  assert(check.must(store.load(s, leaf)).claim == "builder-two",
    "the claim names the second builder")
  assert(vrd.cmd_verdict(s, leaf, "accept", 9, "bbb2222", "",
      "builder-one") == 0,
    "the first builder judges the diff they built")
  local done = check.must(store.load(s, leaf))
  check.equal(done.verdict, "accept", "the accept replaces the rework verdict")
  check.equal(done.phase, "land", "and the item leaves check")
end
test_a_past_builder_may_verdict()
