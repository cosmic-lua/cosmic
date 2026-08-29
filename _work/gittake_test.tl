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
local item = require("_work.item")
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
  local root = file_item(s, "an outcome", "")
  local peer = file_item(s, "a lesser outcome", "")
  assert(cmp.cmd_compare(s, root, peer, false) == 0)
  local out: {string} = {}
  for k = 1, n do
    out[#out + 1] = file_item(s, ("slice %d"):format(k), root)
  end
  return out
end

--- Hand a leaf over under `builder` carrying `pr`. The handover is
--- forced when the store has an origin: a fixture's origin is a file
--- path, so the gate that reads the PR from GitHub refuses when it
--- cannot see one — which is not the behavior under test here.
local function handed_over(s: store.Store, id: string, builder: string,
    pr: integer)
  give_spec(s, id)
  assert(verbs.cmd_take(s, id, builder, 0, false, "") == 0)
  assert(verbs.cmd_take(s, id, builder, pr, true,
      "fixture: file remote, no PR to read") == 0)
end

--- Every open sidecar, the map the pure decision reads.
local function specs_of(s: store.Store): act.Specs
  local out: act.Specs = {}
  for _, i in ipairs(check.must(store.list(s))) do
    if item.is_open(i) then
      out[i.id] = store.read_spec(s, i.id)
    end
  end
  return out
end

-- Take claims the review it offers, in one call.
local function test_take_claims_the_offered_review()
  local s = init_state_repo("take-review")
  local leaves = rooted_leaves(s, 1)
  handed_over(s, leaves[1], "builder-a", 11)
  assert(take.cmd_take(s, "reviewer-z") == 0)
  assert(check.must(store.load(s, leaves[1])).reviewer == "reviewer-z",
    "the review claim landed with the offer")
end
test_take_claims_the_offered_review()

-- Take claims the pull it offers: the claim lands under the taking
-- session.
local function test_take_claims_the_offered_pull()
  local s = init_state_repo("take-pull")
  local leaves = rooted_leaves(s, 1)
  give_spec(s, leaves[1])
  assert(take.cmd_take(s, "session-z") == 0)
  local pulled = check.must(store.load(s, leaves[1]))
  assert(pulled.claim == "session-z",
    "the pull and its claim are one call")
end
test_take_claims_the_offered_pull()

-- The lost race: clone B claims the top review; clone A, still on its
-- stale read, takes — the compare-and-swap refuses its first
-- candidate and the walk claims the next one.
local function test_take_walks_past_a_remotely_claimed_candidate()
  local a, b = init_shared("take-race")
  local leaves = rooted_leaves(a, 2)
  handed_over(a, leaves[1], "builder-a", 21)
  handed_over(a, leaves[2], "builder-a", 22)
  assert(store.sync(b))
  -- B wins the race on whatever A's seeded walk would offer first:
  -- the same decision A's take will make, made here from A's stale
  -- read, then claimed remotely through B.
  local all = check.must(store.list(a))
  local first = act.next_action(all, specs_of(a), "session-a", {},
    "session-a")
  assert(first.kind == "review", "two handed-over items offer a review")
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

-- A kind with no lock reports as bare next does, mutating nothing.
local function test_take_reports_unclaimable_kinds_untouched()
  local s = init_state_repo("take-advice")
  local root = file_item(s, "an outcome", "")
  local peer = file_item(s, "a lesser outcome", "")
  assert(cmp.cmd_compare(s, root, peer, false) == 0)
  local leaf = file_item(s, "an unrefined item", root)
  local before = fixture.commits(s)
  assert(take.cmd_take(s, "session-z") == 0)
  assert(fixture.commits(s) == before,
    "an unclaimable answer (refine) writes nothing")
  assert(check.must(store.load(s, leaf)).claim == "",
    "and the item stands where it was")
end
test_take_reports_unclaimable_kinds_untouched()

print("all take-mode tests passed")
