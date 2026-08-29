#!/usr/bin/env cosmic
-- `commit_and_publish` under a lost push race: the mutation is
-- dropped whole, the checkout re-synced, and the refusal is
-- `store.LOST_RACE` — never a replay of a commit whose preconditions
-- the winner may have falsified. The re-run is the verb's, and it
-- decides afresh against the merged board — where every gate,
-- the doing bound included, is re-applied.

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

--- A minimal valid workable item — under a parent the store never
--- checks, the same convention `store_test.tl` uses.
local function make_item(over?: {string: any}): item.Item
  local t: {string: any} = {
    id = fresh_id(), title = "filler", parent = PARENT,
  }
  for k, v in pairs(over or {}) do
    t[k] = v
  end
  return check.must(item.decode(t))
end

-- A lost race is a refusal, not a replay: the commit is dropped, the
-- checkout holds the winner's state, and the refusal is LOST_RACE by
-- identity.
local function test_a_lost_race_drops_the_mutation_and_refuses()
  local a, b = init_shared("gate-lost")
  -- `a` moves the remote forward, so `b`'s push below is rejected
  -- against a remote it has not seen.
  local touched = make_item()
  assert(store.save(a, touched, "a moves the remote forward"))
  assert(store.publish(a))

  local mine = make_item()
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
  local touched = make_item()
  assert(store.save(a, touched, "a moves the remote forward"))
  assert(store.publish(a))

  local mine = make_item()
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

-- What a re-run's take would see: the doing bound, applied to the
-- merged board — a board another session filled while this one was
-- deciding refuses the take the stale read would have admitted.
local function test_the_merged_board_carries_the_doing_bound()
  local a, b = init_shared("gate-bound")
  for k = 1, flow.DOING_LIMIT do
    assert(store.save(a, make_item({claim = ("wake-%d"):format(k)}),
        "filler " .. fresh_id():sub(1, 8)))
  end
  assert(store.publish(a))
  assert(store.sync(b))
  local merged = check.must(store.list(b))
  assert(flow.doing_refusal(merged) ~= nil,
    "a take against the merged board is the verb's to refuse")
end
test_the_merged_board_carries_the_doing_bound()

-- A decomposition clears the locks on the item that became a
-- container: a claim or review standing on it locks nothing anyone
-- can build. The write travels with the child's commit, which is why
-- it is returned rather than saved.
local function test_containered_clears_the_locks()
  local untouched = make_item()
  assert(#gate.containered(untouched) == 0,
    "an unclaimed parent has nothing to clear")
  local held = make_item({claim = "session-A", reviewer = "review-1"})
  local out = gate.containered(held)
  assert(#out == 1 and out[1].claim == "" and out[1].reviewer == "",
    "the claim and the review clear together")
end
test_containered_clears_the_locks()
