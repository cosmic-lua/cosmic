#!/usr/bin/env cosmic
-- The over-limit rebase check in `commit_and_publish`: it must refuse
-- only a mutation that ARRIVES into a full column. A write that leaves
-- the item where it stands — a spec touch, blocker bookkeeping — is
-- exactly what drains an over-limit column, so it must stay editable
-- even when it loses the push race, while an arriving move into the
-- same column is still refused.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local store = require("_work.store")

local init_shared = fixture.init_shared

local counter = 0

--- A fresh deterministic id; later calls sort later.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

local PARENT = check.must(ksuid.encode(1690000000, ("\1"):rep(16)))

--- A minimal valid workable item in `phase` — under a parent the store
--- never checks, the same convention `store_test.tl` uses.
local function make_item(phase: string): item.Item
  return check.must(item.decode({
        id = fresh_id(), title = "filler", parent = PARENT, phase = phase,
      }))
end

--- Push `plan` one item past its limit — one save per filler, one
--- publish for the lot, so the column starts over-limit with no gate
--- ever having refused an arrival (that up-front WIP check lives in
--- `cmd_new`/`cmd_move`, not here).
local function fill_plan_over_limit(s: store.Store)
  for _ = 1, flow.LIMITS["plan"] + 1 do
    assert(store.save(s, make_item("plan"), "filler " .. fresh_id():sub(1, 8)))
  end
  assert(store.publish(s))
end

-- A same-phase write on an over-limit column publishes after losing
-- the race: the column stays editable by the mutations that drain it.
local function test_a_non_arriving_write_survives_an_over_limit_rebase()
  local a, b = init_shared("gate-write")
  fill_plan_over_limit(a)
  assert(store.sync(b))

  -- `a` moves the remote forward once more, so `b`'s push below loses
  -- the race and rebases onto a column that is still over its limit.
  local touched = make_item("plan")
  assert(store.save(a, touched, "a moves the remote forward"))
  assert(store.publish(a))

  local mine = make_item("plan")
  local ok, err = gate.commit_and_publish(b, mine, "a spec touch",
    ("spec %s"):format(mine.id:sub(1, 8)), "plan")
  assert(ok, "a same-phase write must survive an over-limit rebase: "
    .. tostring(err))
end
test_a_non_arriving_write_survives_an_over_limit_rebase()

-- An arriving move into the same over-limit column is still refused,
-- carrying the reworded message: an arrival, not "a concurrent move"
-- whether or not one happened.
local function test_an_arrival_is_still_refused_over_the_limit()
  local a, b = init_shared("gate-arrival")
  fill_plan_over_limit(a)
  assert(store.sync(b))

  local touched = make_item("plan")
  assert(store.save(a, touched, "a moves the remote forward"))
  assert(store.publish(a))

  local mine = make_item("plan")
  local ok, err = gate.commit_and_publish(b, mine, nil,
    ("new %s"):format(mine.id:sub(1, 8)), nil)
  assert(not ok, "an arrival into an over-limit column must be refused")
  assert(err:find("plan is over %d+ and this mutation arrives into it"),
    "got: " .. err)
end
test_an_arrival_is_still_refused_over_the_limit()

-- The two grounds `land_refusal` reports are different repairs — one
-- needs a review, the other a PR number — so each is checked for the
-- message it carries, not merely for refusing.
local function test_land_refusal_names_what_is_missing()
  local ready = make_item("check")
  ready.verdict = "accept"
  ready.pr = 42
  assert(gate.land_refusal(ready) == nil,
    "an accept naming its PR enters land")

  local unjudged = make_item("check")
  unjudged.pr = 42
  local no_verdict = gate.land_refusal(unjudged)
  assert(no_verdict ~= nil and no_verdict:find("has no verdict", 1, true),
    "got: " .. tostring(no_verdict))

  local bounced = make_item("check")
  bounced.verdict = "request changes"
  bounced.pr = 42
  local wrong = gate.land_refusal(bounced)
  assert(wrong ~= nil and wrong:find("has request changes", 1, true),
    "a non-accept verdict is named as what it is: " .. tostring(wrong))

  local unnumbered = make_item("check")
  unnumbered.verdict = "accept"
  local no_pr = gate.land_refusal(unnumbered)
  assert(no_pr ~= nil and no_pr:find("names none", 1, true),
    "an accept with no PR has nothing to merge: " .. tostring(no_pr))
end
test_land_refusal_names_what_is_missing()
