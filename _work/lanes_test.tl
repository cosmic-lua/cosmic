#!/usr/bin/env cosmic
-- Lane health as board state: mint's idempotency and auto-close
-- guards, record's change-gated commit, and observe's offline path.
-- The network call itself (`observe_one`'s GET) is exercised only
-- live, against a real GitHub token; these tests drive `record` and
-- `mint` with a fake facts table, the way `cmd_sync` would after a
-- real `observe` returned one.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local item = require("_work.item")
local lanes = require("_work.lanes")
local store = require("_work.store")

local init_state_repo = fixture.init_state_repo

local RED: {string: string} = {["release.yml"] = "failure",
  ["fuzz.yml"] = "success", ["docs.yml"] = "success"}
local GREEN: {string: string} = {["release.yml"] = "success",
  ["fuzz.yml"] = "success", ["docs.yml"] = "success"}

--- The one open repair item carrying `lane`, nil when there is none.
local function repair_for(all: {item.Item}, lane: string): item.Item
  for _, it in ipairs(all) do
    if item.is_open(it) and it.lane == lane then
      return it
    end
  end
  return nil
end

-- Two red observations of the same lane mint exactly one repair item:
-- the lane's filename is the idempotency key `mint` searches on
-- before ever filing one — five red days cost one item, not five.
local function test_mint_is_idempotent_per_lane()
  local s = init_state_repo("mint-idempotent")
  assert(lanes.mint(s, RED))
  assert(repair_for(check.must(store.list(s)), "release.yml") ~= nil,
    "one repair item filed for the red lane")

  assert(lanes.mint(s, RED))
  local all = check.must(store.list(s))
  local count = 0
  for _, it in ipairs(all) do
    if it.lane == "release.yml" then count = count + 1 end
  end
  assert(count == 1,
    "a second red observation mints nothing new: " .. tostring(count))
end
test_mint_is_idempotent_per_lane()

-- A lane back to green closes its UNCLAIMED repair item, as
-- not-planned — the monitor observed a fact, it never completed work.
local function test_green_closes_an_unclaimed_repair()
  local s = init_state_repo("mint-closes")
  assert(lanes.mint(s, RED))
  local repair = repair_for(check.must(store.list(s)), "release.yml")
  assert(repair ~= nil and item.is_open(repair), "the repair starts open")

  assert(lanes.mint(s, GREEN))
  local closed = check.must(store.load(s, repair.id))
  assert(not item.is_open(closed), "the green lane closes its repair")
  assert(closed.resolution == "not-planned",
    "auto-closed as not-planned, never completed: " .. closed.resolution)
end
test_green_closes_an_unclaimed_repair()

-- A CLAIMED repair is left alone even when its lane goes green: the
-- monitor never undoes a builder's in-flight claim.
local function test_a_claimed_repair_is_left_alone_on_green()
  local s = init_state_repo("mint-claimed")
  assert(lanes.mint(s, RED))
  local repair = repair_for(check.must(store.list(s)), "release.yml")
  assert(repair ~= nil)
  repair.claim = "session-a"
  assert(store.save(s, repair, ("take %s by session-a"):format(
        repair.id:sub(1, 8))))

  assert(lanes.mint(s, GREEN))
  local still = check.must(store.load(s, repair.id))
  assert(item.is_open(still), "a claimed repair stays open on green")
  assert(still.claim == "session-a", "and the claim is untouched")
end
test_a_claimed_repair_is_left_alone_on_green()

-- record writes and commits ONLY when the facts changed from what is
-- already recorded; a re-observation that agrees with the last one
-- commits nothing, so the log records a fact CHANGING, not a fact
-- being re-confirmed every sync.
local function test_record_commits_only_on_change()
  local s = init_state_repo("record-change")
  local facts: {string: string} = {["release.yml"] = "success",
    ["fuzz.yml"] = "success", ["docs.yml"] = "success"}
  local before = fixture.commits(s)
  assert(lanes.record(s, facts), "the first observation is new, and commits")
  assert(fixture.commits(s) == before + 1, "exactly one commit")

  local ok, err = lanes.record(s, facts)
  assert(not ok, "an unchanged observation records nothing")
  assert(err == "", "and carries no error — this is a no-op, not a failure")
  assert(fixture.commits(s) == before + 1, "so the commit count does not move")

  facts["fuzz.yml"] = "failure"
  assert(lanes.record(s, facts), "a real change commits again")
  assert(fixture.commits(s) == before + 2)
end
test_record_commits_only_on_change()

-- observe needs a slug to address GitHub with; a checkout with no
-- origin has none, so the whole observation comes back "unknown" —
-- the same shape a token-less or offline sync sees — with no network
-- ever touched, which is what makes this safe to run in CI.
local function test_observe_with_no_origin_is_unknown_not_red()
  local s = init_state_repo("observe-no-origin")
  local facts, err = lanes.observe(s)
  assert(facts == nil, "no slug to address means no facts")
  assert(err:find("no origin remote", 1, true) ~= nil, "got: " .. err)
end
test_observe_with_no_origin_is_unknown_not_red()
