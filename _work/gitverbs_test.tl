#!/usr/bin/env cosmic
-- The phase crossings against scratch state repositories: `move` and
-- `done`, their refusals, and the properties that hold across one
-- mutation — one commit per change, a WIP limit that binds arrivals
-- but never returns, a de-phase that cannot outlive the child that
-- caused it, and a container that comes back to the board when its
-- last child closes. What the sidecar itself has to say for an item to
-- cross is `_work/gitspec_test.tl`.

local check = require("cosmic.check")
local child = require("cosmic.child")
local flow = require("_work.flow")
local store = require("_work.store")
local fixture = require("_work.fixture")
local verbs = require("_work.gitverbs")
local graph = require("_work.gitgraph")
local vrd = require("_work.gitverdict")

local init_state_repo = fixture.init_state_repo
local init_shared = fixture.init_shared
local file_item = fixture.file_item
local commits = fixture.commits
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

-- Decomposition writes into the unbounded `backlog`, so no WIP limit
-- can refuse it however deep the board is — that is what separating
-- placement from commitment buys, and it is what keeps a stalled
-- refinement queue from starving the highest-placed roots. Filed here
-- against a clone that moved first: the stale run is refused with
-- LOST_RACE, and the RE-RUN — the up-front gate deciding against the
-- MERGED state, vacated credit and all — reaches the same verdict the
-- deleted post-race revalidation had to reproduce.
local function test_a_decomposition_is_never_refused_by_a_full_board()
  local a, b = init_shared("decompose")
  local goal, leaf = root_with_leaf(a)
  local last_filler = ""
  for i = 1, 9 do
    last_filler = file_item(a, ("filler %d"):format(i), leaf, false)
  end
  -- The parent-to-be stands in `ready`, so the slot its de-phase frees
  -- is not the one its child fills: this decomposition really does add
  -- to the column it arrives in.
  assert(verbs.cmd_move(a, last_filler, "ready", "", 0, true,
      "test fixture") == 0)
  assert(store.sync(b))
  for i = 1, 5 do
    assert(graph.cmd_new(b, ("theirs %d"):format(i), goal, nil, "", true,
        "test fixture") == 0)
  end
  local phased = check.must(store.load(a, last_filler))
  assert(phased.phase == "ready", "the parent-to-be starts on the board")
  assert(graph.cmd_new(a, "the child", phased.id, nil, "", false, "") ~= 0,
    "the stale run is refused, not replayed")
  assert(graph.cmd_new(a, "the child", phased.id, nil, "", false, "") == 0,
    "filing under a deep board is admitted on the re-run")
  local after = check.must(store.load(a, phased.id))
  assert(after.phase == "",
    "and its parent is de-phased into a container: " .. after.phase)
  local r = check.must(child.run({"git", "status", "--porcelain"},
      {cwd = a.root}))
  assert((r.stdout:gsub("%s+$", "")) == "",
    "the mutation leaves no stray change: " .. r.stdout)
end
test_a_decomposition_is_never_refused_by_a_full_board()

-- Closing the last child hands the board back to the container, in
-- `backlog`: verifying the outcome the children were meant to deliver
-- is queued and placed like any other work, and a bounded target could
-- refuse the very commit that closes the child.
local function test_done_returns_a_finished_container_to_backlog()
  local s = init_state_repo("return")
  local _, leaf = root_with_leaf(s)
  local kid = file_item(s, "only child", leaf, false)
  assert(check.must(store.load(s, leaf)).phase == "", "the parent stepped off")
  local before = commits(s)
  assert(verbs.cmd_done(s, kid, "completed", false, "") == 0)
  assert(commits(s) == before + 1, "the close and the return are one commit")
  assert(check.must(store.load(s, leaf)).phase == "backlog",
    "its last child closed, so the container returns to backlog")
  local all = check.must(store.list(s))
  assert(#flow.graph_problems(all) == 0,
    "and nothing is left off the board: "
    .. table.concat(flow.graph_problems(all), "; "))
end
test_done_returns_a_finished_container_to_backlog()

-- A container with children left open stays off the board.
local function test_done_leaves_a_still_decomposing_container_alone()
  local s = init_state_repo("stillbusy")
  local _, leaf = root_with_leaf(s)
  local first = file_item(s, "first child", leaf, false)
  local _second = file_item(s, "second child", leaf, false)
  assert(verbs.cmd_done(s, first, "completed", false, "") == 0)
  assert(check.must(store.load(s, leaf)).phase == "",
    "one child still open: the container keeps decomposing")
end
test_done_leaves_a_still_decomposing_container_alone()

-- The implementer records the PR with the move that hands it over.
local function test_move_records_the_pr()
  local s = init_state_repo("pr")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 4242, false, "") == 0)
  local got = check.must(store.load(s, leaf))
  assert(got.pr == 4242, "the PR rides the move into check: " .. got.pr)
  assert(got.claim == "session-a", "the claim survives it")
end
test_move_records_the_pr()

-- The WIP limit refuses an arrival; a return is admitted over it.
local function test_wip_limits_bind_arrivals_but_never_returns()
  local s = init_state_repo("wip")
  local goal = ""
  local first = ""
  goal, first = root_with_leaf(s)
  give_spec(s, first)
  assert(verbs.cmd_move(s, first, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, first, "do", "session-a", 0, false, "") == 0)
  local pulled: {string} = {first}
  for i = 2, flow.LIMITS["do"] do
    local id = file_item(s, ("slice %d"):format(i), goal, false)
    give_spec(s, id)
    assert(verbs.cmd_move(s, id, "ready", nil, 0, false, "") == 0)
    assert(verbs.cmd_move(s, id, "do", "session-a", 0, false, "") == 0)
    pulled[#pulled + 1] = id
  end
  local extra = file_item(s, "one too many", goal, false)
  give_spec(s, extra)
  assert(verbs.cmd_move(s, extra, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, extra, "do", "session-b", 0, false, "") ~= 0,
    "do is full: the arrival queues")
  assert(check.must(store.load(s, extra)).phase == "ready", "it stayed put")
  assert(verbs.cmd_move(s, pulled[1], "plan", nil, 0, false, "", false,
      "session-a") == 0,
    "a return is never refused for the builder")
  assert(check.must(store.load(s, pulled[1])).claim == "",
    "and a return clears the claim")
end
test_wip_limits_bind_arrivals_but_never_returns()

-- --force is for repair, and a repair the log cannot explain is
-- indistinguishable from ordinary flow.
local function test_force_states_its_reason_and_the_log_keeps_it()
  local s = init_state_repo("why")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, true, "") ~= 0,
    "a bare --force is refused")
  assert(check.must(store.load(s, leaf)).phase == "backlog",
    "and changes nothing")
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, true,
      "repairing a spec the importer mangled") == 0)
  local events = check.must(store.history(s, leaf))
  assert(events[1].subject:find("forced: repairing a spec", 1, true),
    "the reason rides the commit: " .. events[1].subject)
end
test_force_states_its_reason_and_the_log_keeps_it()

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

-- Placement is not commitment, so a full `plan` refuses nothing at
-- intake: the filing lands in `backlog` and waits to be promoted. The
-- up-front gate's half of what the race test checks after a rebase.
local function test_a_full_plan_does_not_refuse_a_filing()
  local s = init_state_repo("elsewhere")
  local goal, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  local _filled = fill_plan(s, goal, flow.LIMITS["plan"])
  assert(occupancy(s, "plan") == flow.LIMITS["plan"], "plan is full")
  local before = occupancy(s, "backlog")
  assert(graph.cmd_new(s, "a child of a ready parent", leaf, nil, "",
      false, "") == 0,
    "a full plan does not refuse intake: the child enters backlog")
  assert(occupancy(s, "backlog") == before + 1, "and it was written")
  assert(occupancy(s, "plan") == flow.LIMITS["plan"], "plan is untouched")
end
test_a_full_plan_does_not_refuse_a_filing()

-- `land` is where the merge happens, and `gitboard land` reads it
-- back from the verdict and PR the item carries. An arrival carrying
-- neither is an item `next` answers `finish` for and `land` refuses
-- forever, so the arrival is what gets refused instead.
local function test_move_into_land_needs_an_accept()
  local s = init_state_repo("land-gate")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 77, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "land", nil, 0, false, "") ~= 0,
    "an item with no verdict does not enter land")
  assert(check.must(store.load(s, leaf)).phase == "check", "and does not move")

  -- A non-accept verdict is a decision too, and it is not this one.
  assert(vrd.cmd_verdict(s, leaf, "request changes", 0, "abc1234",
      "none: test") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "land", nil, 0, false, "") ~= 0,
    "a request-changes verdict is not a standing accept")

  -- `--force` is the repair path, here as at every other gate.
  assert(verbs.cmd_move(s, leaf, "land", nil, 0, true,
      "repairing a stuck item") == 0, "--force --why still passes")
end
test_move_into_land_needs_an_accept()

-- Nothing cleared `verdict`/`verdict_head` except the next verdict, so
-- an accepted item sent back for rework kept its accept and could
-- re-enter land carrying it — merging a head nobody reviewed. Leftward
-- motion out of a judged phase drops the judgment with it.
local function test_return_out_of_land_clears_the_verdict()
  local s = init_state_repo("land-return")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 88, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "abc1234", "") == 0)
  local accepted = check.must(store.load(s, leaf))
  assert(accepted.phase == "land" and accepted.verdict == "accept",
    "the accept stands before the return")

  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  local reworking = check.must(store.load(s, leaf))
  assert(reworking.verdict == "", "the accept did not survive the return")
  assert(reworking.verdict_head == "", "nor the head it judged")
  assert(reworking.enable == "", "nor the countermeasure it filed")
  -- The return cleared the claim with the verdict, so the rework
  -- handover names its builder again.
  assert(verbs.cmd_move(s, leaf, "check", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "land", nil, 0, false, "") ~= 0,
    "so reworked work cannot re-enter land on the old accept")
end
test_return_out_of_land_clears_the_verdict()

-- Leaving `do` abandons work in progress, so a live foreign claim
-- holds against a bare backward move; the builder's own return stays
-- free and still clears the claim.
local function test_a_foreign_backward_move_needs_force()
  local s = init_state_repo("abandon")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "", false,
      "session-b") ~= 0,
    "another session cannot silently abandon a live claim")
  local held = check.must(store.load(s, leaf))
  assert(held.phase == "do" and held.claim == "session-a",
    "the item and its claim stayed put")
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, true,
      "the builder's session died mid-slice", false, "session-b") == 0,
    "a forced takeover with --why goes through")
end
test_a_foreign_backward_move_needs_force()

local function test_the_builders_own_return_stays_free()
  local s = init_state_repo("ownreturn")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "", false,
      "session-a") == 0,
    "the builder bounces their own work without force")
  assert(check.must(store.load(s, leaf)).claim == "",
    "and the return clears the claim as before")
end
test_the_builders_own_return_stays_free()
