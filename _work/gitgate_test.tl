#!/usr/bin/env cosmic
-- `commit_and_publish` under a lost push race: the mutation is
-- dropped whole, the checkout re-synced, and the refusal is
-- `store.LOST_RACE` — never a replay of a commit whose preconditions
-- the winner may have falsified. The re-run is the verb's, and it
-- decides afresh: a re-run of a drainable write publishes, and a
-- re-run of an over-limit arrival meets the verb's own up-front
-- `wip_refusal` on the merged board — where the old post-race closure
-- re-asked only the limit and had to reproduce force and vacated
-- semantics to avoid reversing decisions already made.

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

-- A lost race is a refusal, not a replay: the commit is dropped, the
-- checkout holds the winner's state, and the refusal is LOST_RACE by
-- identity.
local function test_a_lost_race_drops_the_mutation_and_refuses()
  local a, b = init_shared("gate-lost")
  fill_plan_over_limit(a)
  assert(store.sync(b))

  -- `a` moves the remote forward once more, so `b`'s push below is
  -- rejected against a remote it has not seen.
  local touched = make_item("plan")
  assert(store.save(a, touched, "a moves the remote forward"))
  assert(store.publish(a))

  local mine = make_item("plan")
  local ok, err = gate.commit_and_publish(b, mine, "a spec touch",
    ("spec %s"):format(mine.id:sub(1, 8)))
  assert(not ok and err == store.LOST_RACE, "got: " .. tostring(err))
  local merged = check.must(store.list(b))
  assert(flow.by_id(merged)[touched.id] ~= nil,
    "the checkout was re-synced onto the winner's state")
  assert(flow.by_id(merged)[mine.id] == nil,
    "and the dropped mutation is gone whole")
end
test_a_lost_race_drops_the_mutation_and_refuses()

-- The re-run is the compare-and-swap completing: the same mutation,
-- decided and committed again against the merged state, publishes.
local function test_the_rerun_publishes_against_the_merged_state()
  local a, b = init_shared("gate-rerun")
  fill_plan_over_limit(a)
  assert(store.sync(b))
  local touched = make_item("plan")
  assert(store.save(a, touched, "a moves the remote forward"))
  assert(store.publish(a))

  local mine = make_item("plan")
  local ok, err = gate.commit_and_publish(b, mine, "a spec touch",
    ("spec %s"):format(mine.id:sub(1, 8)))
  assert(not ok and err == store.LOST_RACE, "got: " .. tostring(err))
  local again, aerr = gate.commit_and_publish(b, mine, "a spec touch",
    ("spec %s"):format(mine.id:sub(1, 8)))
  assert(again, "the re-run publishes: " .. tostring(aerr))
  assert(store.sync(a))
  assert(check.must(store.load(a, mine.id)).id == mine.id,
    "and the mutation reaches the remote")
end
test_the_rerun_publishes_against_the_merged_state()

-- What the re-run's gate would see: the verb's own up-front WIP
-- refusal, applied to the merged board, refuses an over-limit
-- arrival — the check the deleted post-race closure approximated.
local function test_the_merged_board_carries_the_wip_refusal()
  local a, b = init_shared("gate-wip")
  fill_plan_over_limit(a)
  assert(store.sync(b))
  local merged = check.must(store.list(b))
  assert(gate.wip_refusal(flow.board(merged), nil, "plan") ~= nil,
    "an arrival into the over-limit column is the verb's to refuse")
  assert(gate.wip_refusal(flow.board(merged), nil, "plan", "plan") == nil,
    "with the vacated credit honoured exactly as up front")
end
test_the_merged_board_carries_the_wip_refusal()

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
