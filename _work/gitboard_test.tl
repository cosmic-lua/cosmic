#!/usr/bin/env cosmic
-- The dispatcher's id resolution: every id-taking argument position —
-- not only the first — accepts a rendered handle, and a handle that
-- names nothing is refused the same way a bad prefix is. The verbs
-- themselves are exercised with resolved ids elsewhere
-- (`_work/gitcompare_test.tl`, `_work/gitgraph_test.tl`); this is the
-- dispatch layer in `_work/gitboard.tl` that resolves what a session
-- typed before a verb ever sees it.

local check = require("cosmic.check")
local cmp = require("_work.gitcompare")
local fixture = require("_work.fixture")
local gitboard = require("_work.gitboard")
local store = require("_work.store")
local tail = require("_work.tail")

local init_state_repo = fixture.init_state_repo
local file_item = fixture.file_item

-- `attach`'s PARENT slot: a handle-form second argument resolves the
-- same as a prefix would, so a session pasting a handle from `show`
-- output can attach with it directly.
local function test_attach_resolves_a_handle_form_parent()
  local s = init_state_repo("attach-handle")
  local root = file_item(s, "an outcome", "")
  local leaf = file_item(s, "a workable slice", "")
  assert(gitboard.main("attach", leaf, tail.handle(root), "--dir", s.root) == 0,
    "a handle-form parent should resolve")
  local it = check.must(store.load(s, leaf))
  assert(it.parent == root, "and the attach actually landed")
end
test_attach_resolves_a_handle_form_parent()

-- `compare`'s OTHER slot: same handle form, same resolution.
local function test_compare_resolves_a_handle_form_other()
  local s = init_state_repo("compare-handle")
  local low = file_item(s, "the lesser outcome", "")
  local high = file_item(s, "the greater outcome", "")
  assert(gitboard.main("compare", high, tail.handle(low), "--dir", s.root) == 0,
    "a handle-form OTHER should resolve")
  local winner = check.must(store.load(s, high))
  assert(#winner.beats == 1 and winner.beats[1] == low,
    "and the comparison actually landed")
end
test_compare_resolves_a_handle_form_other()

-- A handle naming nothing is refused cleanly in a secondary slot too
-- — no crash, just the same "no item matches" store gives arg 1.
local function test_secondary_slot_refuses_a_handle_that_matches_nothing()
  local s = init_state_repo("compare-handle-miss")
  local low = file_item(s, "the lesser outcome", "")
  local high = file_item(s, "the greater outcome", "")
  assert(gitboard.main("compare", high, "«ZZZZ_ZZZZ»", "--dir", s.root) ~= 0,
    "a handle matching nothing is refused")
  local winner = check.must(store.load(s, high))
  assert(#winner.beats == 0, "and nothing was recorded")
  local loser = check.must(store.load(s, low))
  assert(#loser.beats == 0, "the unrelated item is untouched")
  assert(cmp.cmd_compare(s, high, low) == 0,
    "the store is still writable after the refusal")
end
test_secondary_slot_refuses_a_handle_that_matches_nothing()
