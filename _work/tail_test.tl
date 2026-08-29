#!/usr/bin/env cosmic
-- tail is a pure derivation over an item's id: handle rendering, shape
-- detection, and resolve's exact/case-folded/refusal arms are pinned
-- directly, with no store and no git involved.

local check = require("cosmic.check")
local item = require("_work.item")
local tail = require("_work.tail")

--- A 27-char id with a chosen 8-char tail, so a test controls exactly
--- what `resolve` and `handle` see without depending on real KSUID
--- randomness. Two distinct fillers keep two same-tail items from
--- sharing one id.
--- @param t string The last 8 characters
--- @param filler string One character to pad the leading 19 with
--- @return string A 27-character id
local function make_id(t: string, filler?: string): string
  return (filler or "0"):rep(19) .. t
end

--- An item carrying exactly the given id.
--- @param id string The id
--- @param title string The title
--- @return item.Item The decoded item
local function make(id: string, title: string): item.Item
  return check.must(item.decode({id = id, title = title}))
end

local function test_handle_hyphenates_and_wraps_the_last_eight_characters()
  local id = make_id("Q4TX9GMD")
  assert(tail.handle(id) == "«Q4TX_9GMD»", tail.handle(id))
end
test_handle_hyphenates_and_wraps_the_last_eight_characters()

local function test_is_tail_shape_accepts_both_forms()
  assert(tail.is_tail_shape("s1WSJ6A3"), "divider-free")
  assert(tail.is_tail_shape("s1WS-J6A3"), "hyphenated after the 4th")
  assert(tail.is_tail_shape("«s1WS_J6A3»"), "a pasted, wrapped handle")
end
test_is_tail_shape_accepts_both_forms()

local function test_is_tail_shape_rejects_malformed_input()
  assert(not tail.is_tail_shape("s1WSJ6A"), "too short")
  assert(not tail.is_tail_shape("s1WSJ6A33"), "too long")
  assert(not tail.is_tail_shape("s1W-SJ6A3"), "hyphen in the wrong place")
  assert(not tail.is_tail_shape("s1WS.J6A3"), "period is not a valid divider")
  assert(not tail.is_tail_shape(""), "empty")
end
test_is_tail_shape_rejects_malformed_input()

local function test_resolve_matches_exactly_hyphenated_or_not()
  local id = make_id("Q4TX9GMD")
  local all: {item.Item} = {make(id, "a slice")}
  assert(check.must(tail.resolve(all, "Q4TX9GMD")) == id, "hyphen-free")
  assert(check.must(tail.resolve(all, "Q4TX-9GMD")) == id, "hyphenated")
end
test_resolve_matches_exactly_hyphenated_or_not()

local function test_resolve_accepts_a_pasted_wrapped_handle()
  local id = make_id("d0x137YJ")
  local all: {item.Item} = {make(id, "a slice")}
  assert(check.must(tail.resolve(all, "«d0x1_37YJ»")) == id,
    "a copy-pasted rendered handle resolves like any other tail")
end
test_resolve_accepts_a_pasted_wrapped_handle()

local function test_resolve_accepts_a_hyphenated_paste_for_backward_tolerance()
  local id = make_id("d0x137YJ")
  local all: {item.Item} = {make(id, "a slice")}
  assert(check.must(tail.resolve(all, "«d0x1-37YJ»")) == id,
    "a handle copied before the divider changed still resolves")
end
test_resolve_accepts_a_hyphenated_paste_for_backward_tolerance()

local function test_resolve_falls_back_to_case_folded_match()
  local id = make_id("Q4TXaBcD")
  local all: {item.Item} = {make(id, "a slice")}
  -- Neither typed form is an exact match (case differs), so both
  -- exercise the case-folded stage, not the exact one.
  assert(check.must(tail.resolve(all, "q4txabcd")) == id, "lowercased")
  assert(check.must(tail.resolve(all, "q4tx-abcd")) == id,
    "lowercased and hyphenated")
end
test_resolve_falls_back_to_case_folded_match()

local function test_resolve_prefers_an_exact_match_over_a_folded_one()
  local exact = make_id("Q4TXABCD")
  local folded = make_id("q4txabcd", "1")
  local all: {item.Item} = {make(exact, "exact"), make(folded, "folded")}
  assert(check.must(tail.resolve(all, "Q4TXABCD")) == exact,
    "the exact stage wins before the folded stage is ever tried")
end
test_resolve_prefers_an_exact_match_over_a_folded_one()

local function test_resolve_refuses_an_exact_ambiguity()
  local one = make_id("Q4TXABCD")
  local other = make_id("Q4TXABCD", "1")
  local all: {item.Item} = {make(one, "a"), make(other, "b")}
  local id, err = tail.resolve(all, "Q4TXABCD")
  assert(id == nil, "two items share this tail")
  assert(err:find("ambiguous", 1, true) and err:find("Q4TXABCD", 1, true), err)
end
test_resolve_refuses_an_exact_ambiguity()

local function test_resolve_refuses_a_folded_ambiguity()
  local one = make_id("Q4TXABCD")
  local other = make_id("q4txabcd", "1")
  local all: {item.Item} = {make(one, "a"), make(other, "b")}
  -- Mixed case matches neither exactly, so both candidates surface
  -- only once folding runs.
  local id, err = tail.resolve(all, "Q4TXabcd")
  assert(id == nil, "the fold matches both")
  assert(err:find("ambiguous", 1, true), err)
end
test_resolve_refuses_a_folded_ambiguity()

local function test_resolve_refuses_no_match()
  local all: {item.Item} = {make(make_id("Q4TX9GMD"), "a slice")}
  local id, err = tail.resolve(all, "ZZZZZZZZ")
  assert(id == nil, "no item carries that tail")
  assert(err:find("no item matches tail", 1, true), err)
end
test_resolve_refuses_no_match()
