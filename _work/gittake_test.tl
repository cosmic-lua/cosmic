#!/usr/bin/env cosmic
-- `take_review`'s mutual exclusion is exact-string equality against
-- `it.reviewer` (`_work.gittake`) — correct whenever two sessions'
-- labels genuinely differ, which is what minting `<kind>-<handle>-
-- <orch8>` (`_work.brief.mint_label`) guarantees across two different
-- physical orchestrator sessions, where a bare `<kind>-<handle>-<n>`
-- convention could not: two orchestrators independently computing the
-- identical string read, to this exact-equality check, as one session
-- re-taking its own review — the collision friction-2026-09-04-work9.md
-- measured. Pinned here directly against `gittake`, one level under
-- the `cmd_take` derivation `_work/gitreview_test.tl` already covers.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local gittake = require("_work.gittake")
local store = require("_work.store")

local init_state_repo = fixture.init_state_repo
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

-- Two minted labels for the SAME item's review, sharing everything but
-- the orchestrator's own 8 characters: the second `take_review` is
-- refused at claim time, exactly as two frankly unrelated session
-- names would be — never read as the first session re-taking its own
-- claim.
local function test_labels_differing_only_in_orch8_exclude_each_other()
  local s = init_state_repo("gittake-orch8")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  local it = check.must(store.load(s, leaf))
  it.claim = "build-abcd1234-11111111"
  it.pr = 7
  it.builders = {it.claim}
  assert(store.save(s, it, "fixture: handed over for review"))

  local first = "review-abcd1234-aaaaaaaa"
  local second = "review-abcd1234-bbbbbbbb"

  it = check.must(store.load(s, leaf))
  assert(gittake.take_review(s, it, first, false, "") == 0,
    "the first orchestrator's minted label claims the review")
  check.equal(check.must(store.load(s, leaf)).reviewer, first)

  it = check.must(store.load(s, leaf))
  assert(gittake.take_review(s, it, second, false, "") ~= 0,
    "a second orchestrator's label — identical but for orch8 — is "
    .. "refused while the first's claim is live, never read as the "
    .. "same session re-taking")
  check.equal(check.must(store.load(s, leaf)).reviewer, first,
    "and the claim did not move")

  -- The holder's own label, re-offered, is still the idempotent yes
  -- `take_review` always gives a live self-claim.
  it = check.must(store.load(s, leaf))
  assert(gittake.take_review(s, it, first, false, "") == 0,
    "the holder's own exact label re-claims cleanly")
  check.equal(check.must(store.load(s, leaf)).reviewer, first)
end

-- The refusal names the live holder verbatim, so a second orchestrator
-- reading it sees the first's actual label — including its distinct
-- orch8 — rather than a generic "someone else" message.
local function test_the_refusal_names_the_live_labels_orch8()
  local s = init_state_repo("gittake-orch8-refusal")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  local it = check.must(store.load(s, leaf))
  it.claim = "build-cafefeed-11111111"
  it.pr = 3
  it.builders = {it.claim}
  assert(store.save(s, it, "fixture: handed over for review"))

  local holder = "review-cafefeed-aaaaaaaa"
  it = check.must(store.load(s, leaf))
  assert(gittake.take_review(s, it, holder, false, "") == 0)

  it = check.must(store.load(s, leaf))
  local old_print = _G.print
  local lines: {string} = {}
  _G.print = function(...: any)
    lines[#lines + 1] = tostring((...))
  end
  local ok, code = pcall(gittake.take_review, s, it,
    "review-cafefeed-bbbbbbbb", false, "")
  _G.print = old_print
  assert(ok, tostring(code))
  assert(code ~= 0, "the takeover is refused with no --force")
  local out = table.concat(lines, "\n")
  assert(out:find("under review by " .. holder, 1, true) ~= nil,
    "the refusal names the exact live label, orch8 included: " .. out)
end
