#!/usr/bin/env cosmic
-- The graph verbs against scratch state repositories: filing an item,
-- the parent edge and the blocker edge, their refusals, and the
-- properties that hold across such a mutation — one commit per
-- change, and locks that cannot outlive the decomposition that made
-- their holder a container.

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
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

local function test_decomposition_is_one_commit()
  local s = init_state_repo("decompose")
  local _, leaf = root_with_leaf(s)
  -- The leaf is mid-build when the child arrives: the decomposition
  -- clears the lock, in the same commit.
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-A", 0, false, "") == 0)
  local before = commits(s)
  local _kid = file_item(s, "a sub-slice", leaf)
  assert(commits(s) == before + 1,
    ("one mutation, one commit: %d -> %d"):format(before, commits(s)))
  local parent = check.must(store.load(s, leaf))
  assert(parent.claim == "",
    "gaining a child clears the lock on the new container")
end
test_decomposition_is_one_commit()

-- Re-parenting after a lost push race: `attach` has no WIP gate up
-- front — triage is a decision already made — so after the race the
-- RE-RUN lands exactly as the first run would have.
local function test_a_reparent_survives_a_rebase()
  local a, b = init_shared("attach-race")
  local goal, leaf = root_with_leaf(a)
  local other = file_item(a, "another leaf", goal)
  assert(store.sync(b))
  for i = 1, 3 do
    assert(graph.cmd_new(b, ("theirs %d"):format(i), goal, nil, "") == 0)
  end
  assert(graph.cmd_attach(a, leaf, other) ~= 0,
    "the stale run is refused, not replayed")
  assert(graph.cmd_attach(a, leaf, other) == 0,
    "the re-run lands against the merged board")
  local after = check.must(store.load(a, leaf))
  assert(after.parent == other, "the re-parent landed: " .. after.parent)
end
test_a_reparent_survives_a_rebase()

-- Attaching under one's own descendant would make a cycle.
local function test_attach_refuses_a_cycle()
  local s = init_state_repo("cycle")
  local _, leaf = root_with_leaf(s)
  local kid = file_item(s, "a child", leaf)
  assert(graph.cmd_attach(s, leaf, kid) ~= 0, "a cycle must be refused")
  assert(check.must(store.load(s, leaf)).parent ~= kid, "and not written")
end
test_attach_refuses_a_cycle()

-- Landing order is a board fact like any other: one verb, one commit,
-- and refusals where hand-editing the field wrote nonsense.
local function test_block_records_landing_order_and_refuses_nonsense()
  local s = init_state_repo("block")
  local goal, first = root_with_leaf(s)
  local second = file_item(s, "the slice that waits", goal)
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
  local goal = file_item(s, "an outcome", "")
  local before: {string: boolean} = {}
  for _, i in ipairs(check.must(store.list(s))) do
    before[i.id] = true
  end
  assert(graph.cmd_new(s, "a cosmopolitan-side slice", goal, nil,
      "whilp/cosmopolitan") == 0)
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

-- Filing and adoption are never refused: todo is unbounded by design
-- — the queue intake writes into can always accept — and the doing
-- bound binds at take, where committing to work is the expensive
-- decision. A board at the bound still files and still adopts.
local function test_filing_is_admitted_at_the_doing_bound()
  local s = init_state_repo("bound")
  local goal, leaf = root_with_leaf(s)
  for k = 1, flow.DOING_LIMIT do
    local id = file_item(s, ("in flight %d"):format(k), goal)
    give_spec(s, id)
    assert(verbs.cmd_take(s, id, ("wake-%d"):format(k), 0, false, "") == 0,
      "the bound admits takes up to its number")
  end
  assert(flow.doing_refusal(check.must(store.list(s))) ~= nil,
    "the board is at the bound")
  local capture = file_item(s, "a capture", "")
  assert(graph.cmd_attach(s, capture, goal) == 0,
    "adoption is admitted at the bound")
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "one-more", 0, false, "") ~= 0,
    "and the take is what the bound refuses")
end
test_filing_is_admitted_at_the_doing_bound()
