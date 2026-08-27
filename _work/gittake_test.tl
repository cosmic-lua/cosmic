#!/usr/bin/env cosmic
-- `next --take`: the offer and the lock in one call. The interesting
-- path is the lost race — a candidate that looked free on a stale
-- read is claimed remotely, the publish's compare-and-swap refuses,
-- and the walk lands on the next candidate instead of fighting or
-- handing two sessions one item.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local act = require("_work.action")
local cmp = require("_work.gitcompare")
local rev = require("_work.gitreview")
local store = require("_work.store")
local take = require("_work.gittake")
local verbs = require("_work.gitverbs")

local init_state_repo = fixture.init_state_repo
local init_shared = fixture.init_shared
local file_item = fixture.file_item
local give_spec = fixture.give_spec

--- A root with a compared peer (so its leaves are placed) plus N
--- workable leaves under it, ids returned in creation order.
local function rooted_leaves(s: store.Store, n: integer): {string}
  local root = file_item(s, "an outcome", "", false)
  local peer = file_item(s, "a lesser outcome", "", false)
  assert(cmp.cmd_compare(s, root, peer, false) == 0)
  local out: {string} = {}
  for k = 1, n do
    out[#out + 1] = file_item(s, ("slice %d"):format(k), root, false)
  end
  return out
end

--- Drive a leaf to check under `builder` carrying `pr`. The handover
--- is forced: a fixture's origin is a file path, so the gate that
--- reads the PR from GitHub refuses when it cannot see one — which is
--- not the behavior under test here.
local function into_check(s: store.Store, id: string, builder: string,
    pr: integer)
  give_spec(s, id)
  assert(verbs.cmd_move(s, id, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, id, "do", builder, 0, false, "") == 0)
  assert(verbs.cmd_move(s, id, "check", nil, pr, true,
      "fixture: file remote, no PR to read") == 0)
end

-- Take claims the review it offers, in one call.
local function test_take_claims_the_offered_review()
  local s = init_state_repo("take-review")
  local leaves = rooted_leaves(s, 1)
  into_check(s, leaves[1], "builder-a", 11)
  assert(take.cmd_take(s, "reviewer-z") == 0)
  assert(check.must(store.load(s, leaves[1])).reviewer == "reviewer-z",
    "the review claim landed with the offer")
end
test_take_claims_the_offered_review()

-- Take claims the pull it offers: the item lands in `do` under the
-- taking session.
local function test_take_claims_the_offered_pull()
  local s = init_state_repo("take-pull")
  local leaves = rooted_leaves(s, 1)
  give_spec(s, leaves[1])
  assert(verbs.cmd_move(s, leaves[1], "ready", nil, 0, false, "") == 0)
  assert(take.cmd_take(s, "session-z") == 0)
  local pulled = check.must(store.load(s, leaves[1]))
  assert(pulled.phase == "do" and pulled.claim == "session-z",
    "the pull and its claim are one call")
end
test_take_claims_the_offered_pull()

-- The lost race: clone B claims the top review; clone A, still on its
-- stale read, takes — the compare-and-swap refuses its first
-- candidate and the walk claims the next one.
local function test_take_walks_past_a_remotely_claimed_candidate()
  local a, b = init_shared("take-race")
  local leaves = rooted_leaves(a, 2)
  into_check(a, leaves[1], "builder-a", 21)
  into_check(a, leaves[2], "builder-a", 22)
  assert(store.sync(b))
  -- B wins the race on whatever A's seeded walk would offer first:
  -- the same decision A's take will make, made here from A's stale
  -- read, then claimed remotely through B.
  local all = check.must(store.list(a))
  local first = act.next_action(all, "session-a", {}, "session-a")
  assert(first.kind == "review", "two check items offer a review")
  assert(rev.cmd_review(b, first.item.id, "session-b", false, "") == 0)
  -- A has not synced: its read still shows the item free.
  assert(take.cmd_take(a, "session-a") == 0)
  local one = check.must(store.load(a, leaves[1]))
  local two = check.must(store.load(a, leaves[2]))
  local mine = one.reviewer == "session-a" and one or
  (two.reviewer == "session-a" and two or nil)
  assert(mine ~= nil, "a lost candidate falls to the next, not to a fight")
  assert(mine.id ~= first.item.id,
    "and the one taken is not the one session-b already holds")
end
test_take_walks_past_a_remotely_claimed_candidate()

-- The walk itself, distinguished from the re-sync-and-recompute
-- backstop: after A's stale read, B claims A's primary AND an accept
-- moves a third item into land — so a post-sync recompute's primary
-- is an unclaimable `finish` and only the stale-read walk can claim
-- the remaining review. Deleting the walk turns the final assertion
-- red; the race test above alone could not (either mechanism
-- delivered it).
local function test_only_the_walk_can_claim_past_the_lost_primary()
  local a, b = init_shared("take-walk")
  local leaves = rooted_leaves(a, 3)
  for k, id in ipairs(leaves) do
    into_check(a, id, "builder-a", 30 + k)
  end
  assert(store.sync(b))
  local all = check.must(store.list(a))
  local first = act.next_action(all, "session-a", {}, "session-a")
  assert(first.kind == "review", "three check items offer a review")
  assert(rev.cmd_review(b, first.item.id, "session-b", false, "") == 0)
  local landed = ""
  for _, id in ipairs(leaves) do
    if id ~= first.item.id and landed == "" then
      landed = id
    end
  end
  local vrd = require("_work.gitverdict")
  assert(vrd.cmd_verdict(b, landed, "accept", 0, "abc1234", "",
      "session-c") == 0, "an accept parks a finish ahead of every review")
  -- A's read is stale: its walk starts from the pre-claim, pre-land
  -- snapshot. The remaining review is reachable only by walking.
  assert(take.cmd_take(a, "session-a") == 0)
  local third = ""
  for _, id in ipairs(leaves) do
    if id ~= first.item.id and id ~= landed then
      third = id
    end
  end
  assert(check.must(store.load(a, third)).reviewer == "session-a",
    "the walk claimed the remaining review from the stale read")
end
test_only_the_walk_can_claim_past_the_lost_primary()

-- A kind with no lock reports as bare next does, mutating nothing.
local function test_take_reports_unclaimable_kinds_untouched()
  local s = init_state_repo("take-advice")
  local root = file_item(s, "an outcome", "", false)
  local peer = file_item(s, "a lesser outcome", "", false)
  assert(cmp.cmd_compare(s, root, peer, false) == 0)
  local leaf = file_item(s, "a backlog item", root, false)
  local before = fixture.commits(s)
  assert(take.cmd_take(s, "session-z") == 0)
  assert(fixture.commits(s) == before,
    "an unclaimable answer (promote) writes nothing")
  assert(check.must(store.load(s, leaf)).phase == "backlog",
    "and the item stands where it was")
end
test_take_reports_unclaimable_kinds_untouched()

print("all take-mode tests passed")
