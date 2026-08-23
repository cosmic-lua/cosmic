#!/usr/bin/env cosmic
-- The graph verbs against scratch state repositories: filing an item,
-- the parent edge and the blocker edge, their refusals, and the
-- properties that hold across such a mutation — one commit per
-- change, a de-phase that cannot outlive the child that caused it,
-- and an intake that a full committed queue does not reach, because
-- placement writes into the unbounded backlog.

local check = require("cosmic.check")
local flow = require("_work.flow")
local store = require("_work.store")
local fixture = require("_work.fixture")
local graph = require("_work.gitgraph")
local verbs = require("_work.gitverbs")

local init_state_repo = fixture.init_state_repo
local init_shared = fixture.init_shared
local file_item = fixture.file_item
local commits = fixture.commits
local root_with_leaf = fixture.root_with_leaf

local function test_decomposition_is_one_commit()
  local s = init_state_repo("decompose")
  local _, leaf = root_with_leaf(s)
  local before = commits(s)
  local _kid = file_item(s, "a sub-slice", leaf, false)
  assert(commits(s) == before + 1,
    ("one mutation, one commit: %d -> %d"):format(before, commits(s)))
  assert(check.must(store.load(s, leaf)).phase == "",
    "gaining a child de-phases the parent")
end
test_decomposition_is_one_commit()

-- The other side of the same race: re-parenting an item that already
-- holds a phase leaves it where it stands, so `attach` is a write and
-- not an entry. It has no WIP gate up front — triage is a decision
-- already made — and the check after a lost push race has to agree, or
-- the board becomes unre-parentable whenever a column is full.
local function test_a_reparent_survives_an_over_limit_rebase()
  local a, b = init_shared("attach-race")
  local goal, leaf = root_with_leaf(a)
  local other = file_item(a, "another leaf", goal, false)
  assert(store.sync(b))
  -- The other clone fills the board, so this clone's re-parent rebases
  -- onto a column it never entered: the item was in backlog before the
  -- attach and is in backlog after it.
  for i = 1, 12 do
    assert(graph.cmd_new(b, ("theirs %d"):format(i), goal, nil, "", true,
        "test fixture") == 0)
  end
  assert(check.must(store.load(a, leaf)).phase == "backlog",
    "the item starts on the board")
  assert(graph.cmd_attach(a, leaf, other) == 0,
    "a re-parent that moves nothing must survive an over-limit rebase")
  local after = check.must(store.load(a, leaf))
  assert(after.phase == "backlog",
    "a re-parent leaves the item where it stands: " .. after.phase)
  assert(after.parent == other, "the re-parent landed: " .. after.parent)
end
test_a_reparent_survives_an_over_limit_rebase()

-- Attaching under one's own descendant would make a cycle.
local function test_attach_refuses_a_cycle()
  local s = init_state_repo("cycle")
  local _, leaf = root_with_leaf(s)
  local kid = file_item(s, "a child", leaf, false)
  assert(graph.cmd_attach(s, leaf, kid) ~= 0, "a cycle must be refused")
  assert(check.must(store.load(s, leaf)).parent ~= kid, "and not written")
end
test_attach_refuses_a_cycle()

-- Landing order is a board fact like any other: one verb, one commit,
-- and refusals where hand-editing the field wrote nonsense.
local function test_block_records_landing_order_and_refuses_nonsense()
  local s = init_state_repo("block")
  local goal, first = root_with_leaf(s)
  local second = file_item(s, "the slice that waits", goal, false)
  assert(graph.cmd_block(s, second, first, false, "") ~= 0,
    "a block with no reason is refused")
  assert(graph.cmd_block(s, second, first, false, "first lands the API") == 0)
  local waited = check.must(store.load(s, second))
  assert(#waited.blocked_by == 1, "the blocker is recorded")
  assert(waited.block_reason[first] == "first lands the API",
    "the reason rides on the edge")
  assert(graph.cmd_block(s, second, first, false, "again") ~= 0,
    "recording it twice records nothing")
  assert(graph.cmd_block(s, second, second, false, "self") ~= 0,
    "an item cannot block itself")
  assert(graph.cmd_block(s, first, second, false, "reverse") ~= 0,
    "and the reverse edge would deadlock both")
  assert(#check.must(store.load(s, first)).blocked_by == 0,
    "the refused edge is not written")
  assert(graph.cmd_block(s, second, first, true, "") == 0, "unblock drops it")
  local freed = check.must(store.load(s, second))
  assert(#freed.blocked_by == 0, "leaving none")
  assert(freed.block_reason[first] == nil, "the reason goes with the edge")
  assert(graph.cmd_block(s, second, first, true, "") ~= 0,
    "and dropping what is not there is refused")
end
test_block_records_landing_order_and_refuses_nonsense()

-- `new --repo` scopes the item's PR to a foreign repo; the field is
-- what makes cross-repo work (a cosmopolitan fix serving a cosmic
-- goal) visible instead of a URL buried in prose.
local function test_new_repo_lands_the_field()
  local s = init_state_repo("cross-repo")
  local goal = file_item(s, "an outcome", "", false)
  local before: {string: boolean} = {}
  for _, i in ipairs(check.must(store.list(s))) do
    before[i.id] = true
  end
  assert(graph.cmd_new(s, "a cosmopolitan-side slice", goal, nil,
      "whilp/cosmopolitan", false, "") == 0)
  local found: string = nil
  for _, i in ipairs(check.must(store.list(s))) do
    if not before[i.id] then
      found = i.id
    end
  end
  assert(found ~= nil, "the new item is on the board")
  local it = check.must(store.load(s, found))
  assert(it.repo == "whilp/cosmopolitan",
    "the field lands on the stored item: " .. it.repo)
end
test_new_repo_lands_the_field()

-- How many items a store's board holds in one phase.
local function occupancy(s: store.Store, phase: string): integer
  return #(flow.board(check.must(store.list(s)))[phase] or {})
end

-- Move `count` leaves under `goal` into plan, returning their ids.
-- Filing alone no longer reaches plan — an item is placed into
-- `backlog` and promoted from there — so filling the committed queue
-- takes the promotion each item would get from `next`.
local function fill_plan(s: store.Store, goal: string,
    count: integer): {string}
  local out: {string} = {}
  for i = 1, count do
    local id = file_item(s, ("filler %d"):format(i), goal, false)
    assert(verbs.cmd_move(s, id, "plan", nil, 0, false, "") == 0,
      "the committed queue has room for filler " .. tostring(i))
    out[#out + 1] = id
  end
  return out
end

-- A decomposition is ONE commit: the child arrives and the parent
-- leaves the board together. Checked against a full `plan`, because
-- that is where a half-applied mutation used to be possible — the
-- child entering while the parent's de-phase was refused would leave
-- a container still counted as workable.
local function test_a_decomposition_is_one_commit_with_plan_full()
  local s = init_state_repo("netzero")
  local goal, leaf = root_with_leaf(s)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  local _filled = fill_plan(s, goal, flow.LIMITS["plan"] - 1)
  assert(occupancy(s, "plan") == flow.LIMITS["plan"], "plan starts full")
  local before = commits(s)
  local kid = file_item(s, "a sub-slice", leaf, false)
  assert(commits(s) == before + 1, "the child and the de-phase are one commit")
  assert(check.must(store.load(s, leaf)).phase == "",
    "the parent left the board")
  assert(check.must(store.load(s, kid)).phase == "backlog",
    "and the child is placed, not committed to")
  assert(occupancy(s, "plan") == flow.LIMITS["plan"] - 1,
    "the parent's slot is freed and nothing takes it")
end
test_a_decomposition_is_one_commit_with_plan_full()

-- A container's second child used to be an ordinary arrival a full
-- `plan` refused. Intake writes into the unbounded `backlog` now, so
-- the limit does not reach it.
local function test_a_full_plan_admits_a_containers_next_child()
  local s = init_state_repo("container")
  local goal, leaf = root_with_leaf(s)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  local _filled = fill_plan(s, goal, flow.LIMITS["plan"] - 1)
  local _first = file_item(s, "the first child", leaf, false)
  local before = occupancy(s, "plan")
  local second = file_item(s, "the second child", leaf, false)
  assert(check.must(store.load(s, second)).phase == "backlog",
    "the second child is admitted into backlog")
  assert(occupancy(s, "plan") == before, "and plan is untouched")
end
test_a_full_plan_admits_a_containers_next_child()

-- Adoption is admitted at any occupancy — triage answers whether the
-- capture is real and under what, never whether to commit to it — so
-- draining an over-bound triage queue is never refused, and what it
-- drains into is `backlog`.
local function test_adoption_lands_in_backlog_at_any_occupancy()
  local s = init_state_repo("adopt")
  local goal, leaf = root_with_leaf(s)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  local _filled = fill_plan(s, goal, flow.LIMITS["plan"] - 1)
  local before = occupancy(s, "plan")
  local under_leaf = file_item(s, "a capture", "", false)
  assert(graph.cmd_attach(s, under_leaf, leaf) == 0,
    "adopting under a workable leaf is admitted")
  assert(check.must(store.load(s, under_leaf)).phase == "backlog",
    "and it is placed, not committed to")
  -- The adoptee lands in backlog and the leaf it adopted under becomes
  -- a container, so the committed queue LOSES a slot rather than
  -- gaining one.
  assert(occupancy(s, "plan") == before - 1,
    "the adopting leaf de-phased and nothing arrived in its place")
  local after_first = occupancy(s, "plan")
  local under_container = file_item(s, "another capture", "", false)
  assert(graph.cmd_attach(s, under_container, leaf) == 0,
    "and so is adopting under the container it became")
  assert(check.must(store.load(s, under_container)).phase == "backlog",
    "the second adoptee is placed too")
  assert(occupancy(s, "plan") == after_first,
    "neither adoption reached the committed queue")
end
test_adoption_lands_in_backlog_at_any_occupancy()
