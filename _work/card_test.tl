#!/usr/bin/env cosmic
-- The card codec is pure: encode omits zero values, decode fills them
-- back in and validates, and the two round-trip through cosmic.literal
-- byte-for-byte. to_issue is pinned against _work.model directly — the
-- blockers grammar the adapter renders must be the one the model reads.

local check = require("cosmic.check")
local cards = require("_work.card")
local literal = require("cosmic.literal")
local model = require("_work.model")

local function full_card(): cards.Card
  return {
    issue = 123, title = "teach the store to fly", phase = "ready",
    epic = false, finding = true, enable = true,
    blocked_by = {7, 9}, claim = "session-a", pr = 456,
    verdict = "request changes", verdict_head = "abc1234",
    resolution = "",
  }
end

local function test_roundtrip_through_literal()
  local c = full_card()
  local text = check.must(literal.format(cards.encode(c)))
  local back = check.must(cards.decode(check.must(literal.parse(text))))
  assert(back.issue == 123, "issue: " .. tostring(back.issue))
  assert(back.title == c.title, "title: " .. back.title)
  assert(back.phase == "ready", "phase: " .. back.phase)
  assert(back.finding and back.enable and not back.epic, "markers")
  assert(#back.blocked_by == 2 and back.blocked_by[2] == 9, "blocked_by")
  assert(back.claim == "session-a", "claim: " .. back.claim)
  assert(back.pr == 456, "pr: " .. tostring(back.pr))
  assert(back.verdict == "request changes", "verdict: " .. back.verdict)
  assert(back.verdict_head == "abc1234", "head: " .. back.verdict_head)
end
test_roundtrip_through_literal()

local function test_encode_omits_zero_values()
  local t = cards.encode({
      issue = 5, title = "t", phase = "plan", epic = false, finding = false,
      enable = false, blocked_by = {}, claim = "", pr = 0, verdict = "",
      verdict_head = "", resolution = "",
    })
  local keys = 0
  for _ in pairs(t) do
    keys = keys + 1
  end
  assert(keys == 3, "want only issue/title/phase, got " .. keys .. " keys")
end
test_encode_omits_zero_values()

local function test_decode_fills_defaults()
  local c = check.must(cards.decode({issue = 5, title = "t", phase = "plan"}))
  assert(c.epic == false and c.finding == false and c.enable == false, "markers")
  assert(#c.blocked_by == 0, "blocked_by")
  assert(c.claim == "" and c.pr == 0 and c.verdict == "", "coordination fields")
end
test_decode_fills_defaults()

local function test_problems_catch_invalid_cards()
  local bad, err = cards.decode({issue = 5, title = "t", phase = "flying"})
  assert(bad == nil, "phase must be validated")
  assert(err:find("unknown phase", 1, true), "got: " .. err)
  local done, derr = cards.decode({issue = 5, title = "t", phase = "done"})
  assert(done == nil, "done needs a resolution")
  assert(derr:find("resolution", 1, true), "got: " .. derr)
  local open, oerr = cards.decode({issue = 5, title = "t", phase = "plan",
      resolution = "completed"})
  assert(open == nil, "an open card must not carry a resolution")
  assert(oerr:find("resolution", 1, true), "got: " .. oerr)
end
test_problems_catch_invalid_cards()

local function test_to_issue_speaks_the_models_blocker_grammar()
  local c = check.must(cards.decode({issue = 12, title = "t", phase = "ready",
        blocked_by = "#124 #125"}))
  local issue = cards.to_issue(c, "whilp/cosmic")
  local blockers = model.blockers(issue.body)
  assert(#blockers == 2, "want 2 blockers, got " .. #blockers)
  assert(blockers[1] == 124 and blockers[2] == 125, "blocker numbers")
  assert(issue.url:find("whilp/cosmic/issues/12", 1, true), "url: " .. issue.url)
end
test_to_issue_speaks_the_models_blocker_grammar()
