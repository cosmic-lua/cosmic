#!/usr/bin/env cosmic
-- The verbs against scratch state repositories: the mutations, their
-- refusals, and the properties that hold across a mutation — one
-- commit per change, a de-phase that cannot outlive the child that
-- caused it, a ready bar that judges the item in front of it, and a
-- container that comes back to the board when its last child closes.

local check = require("cosmic.check")
local child = require("cosmic.child")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local fs = require("cosmic.fs")
local store = require("_work.store")
local fixture = require("_work.fixture")
local verbs = require("_work.gitverbs")
local view = require("_work.gitview")
local vrd = require("_work.gitverdict")

local tmpdir = fixture.tmpdir
local READY_SPEC < const > = fixture.READY_SPEC
local init_state_repo = fixture.init_state_repo
local init_shared = fixture.init_shared
local file_item = fixture.file_item
local commits = fixture.commits
local give_spec = fixture.give_spec
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

-- The same decomposition, losing a race: the whole mutation is
-- refused, so the parent must still be on the board. A de-phase that
-- survived its refused child is a parent that silently left the board
-- and rides along on the next push.
local function test_a_refused_decomposition_leaves_the_parent_phased()
  local a, b = init_shared("refuse")
  local goal, leaf = root_with_leaf(a)
  local last_filler = ""
  for i = 1, 9 do
    last_filler = file_item(a, ("filler %d"):format(i), leaf, false)
  end
  -- The parent-to-be stands in `ready`, so the slot its de-phase frees
  -- is not the one its child fills: this decomposition really does add
  -- to plan, and plan's limit binds it. The leaf is a container now,
  -- and plan holds the other 8 children. The other clone fills plan
  -- past the limit before this one files a tenth, so the tenth loses
  -- the race at the merged state, not locally.
  assert(verbs.cmd_move(a, last_filler, "ready", "", 0, true,
      "test fixture") == 0)
  assert(store.sync(b))
  for i = 1, 5 do
    assert(verbs.cmd_new(b, ("theirs %d"):format(i), goal, nil, "", true,
        "test fixture") == 0)
  end
  local phased = check.must(store.load(a, last_filler))
  assert(phased.phase == "ready", "the parent-to-be starts on the board")
  assert(verbs.cmd_new(a, "the refused child", phased.id, nil, "", false, "") ~= 0,
    "filing under a full plan must be refused after the rebase")
  local after = check.must(store.load(a, phased.id))
  assert(after.phase == "ready",
    "a refused filing leaves its parent on the board: " .. after.phase)
  local r = check.must(child.run({"git", "status", "--porcelain"},
      {cwd = a.root}))
  assert((r.stdout:gsub("%s+$", "")) == "",
    "the refusal leaves no stray change: " .. r.stdout)
end
test_a_refused_decomposition_leaves_the_parent_phased()

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
  -- The other clone pushes plan past its limit, so this clone's
  -- re-parent rebases onto a full column it never entered: the item
  -- was in plan before the attach and is in plan after it.
  for i = 1, 12 do
    assert(verbs.cmd_new(b, ("theirs %d"):format(i), goal, nil, "", true,
        "test fixture") == 0)
  end
  assert(check.must(store.load(a, leaf)).phase == "plan",
    "the item starts on the board")
  assert(verbs.cmd_attach(a, leaf, other) == 0,
    "a re-parent that moves nothing must survive an over-limit rebase")
  local after = check.must(store.load(a, leaf))
  assert(after.phase == "plan",
    "a re-parent leaves the item where it stands: " .. after.phase)
  assert(after.parent == other, "the re-parent landed: " .. after.parent)
end
test_a_reparent_survives_an_over_limit_rebase()

-- The ready bar judges the item being promoted. Another item's broken
-- chain is board health, reported by `status`, never a refusal of a
-- promotion that has nothing to do with it.
local function test_the_ready_bar_is_the_items_own()
  local s = init_state_repo("readybar")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  -- An unrelated broken chain: work under an unranked root.
  local finding = file_item(s, "a finding", "", false)
  local _stray = file_item(s, "work under it", finding, false)
  local all = check.must(store.list(s))
  assert(#flow.graph_problems(all) > 0, "the board does have a problem")
  assert(view.cmd_check(s, leaf) == 0,
    "a sound item meets the bar while another item is broken")
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0,
    "and it may be promoted")
  assert(check.must(store.load(s, leaf)).phase == "ready", "it moved")
end
test_the_ready_bar_is_the_items_own()

-- A hollow spec still refuses, naming the sections it lacks.
local function test_the_ready_bar_still_refuses_a_hollow_spec()
  local s = init_state_repo("hollow")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") ~= 0,
    "no spec, no ready")
  assert(check.must(store.load(s, leaf)).phase == "plan", "it stayed put")
end
test_the_ready_bar_still_refuses_a_hollow_spec()

-- Closing the last child hands the board back to the container: the
-- planner verifies the outcome the children were meant to deliver.
local function test_done_returns_a_finished_container_to_plan()
  local s = init_state_repo("return")
  local _, leaf = root_with_leaf(s)
  local kid = file_item(s, "only child", leaf, false)
  assert(check.must(store.load(s, leaf)).phase == "", "the parent stepped off")
  local before = commits(s)
  assert(verbs.cmd_done(s, kid, "completed", false, "") == 0)
  assert(commits(s) == before + 1, "the close and the return are one commit")
  assert(check.must(store.load(s, leaf)).phase == "plan",
    "its last child closed, so the container returns to plan")
  local all = check.must(store.list(s))
  assert(#flow.graph_problems(all) == 0,
    "and nothing is left off the board: "
    .. table.concat(flow.graph_problems(all), "; "))
end
test_done_returns_a_finished_container_to_plan()

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

-- Re-running a mutation that records the same values says so.
local function test_a_no_op_mutation_is_named()
  local s = init_state_repo("noop")
  local _, leaf = root_with_leaf(s)
  local path = fs.join(tmpdir, "ready-spec.md")
  assert(fs.write(path, READY_SPEC))
  assert(verbs.cmd_spec(s, leaf, path) == 0)
  assert(verbs.cmd_spec(s, leaf, path) ~= 0,
    "the same spec twice records nothing the second time")
end
test_a_no_op_mutation_is_named()

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

-- Attaching under one's own descendant would make a cycle.
local function test_attach_refuses_a_cycle()
  local s = init_state_repo("cycle")
  local _, leaf = root_with_leaf(s)
  local kid = file_item(s, "a child", leaf, false)
  assert(verbs.cmd_attach(s, leaf, kid) ~= 0, "a cycle must be refused")
  assert(check.must(store.load(s, leaf)).parent ~= kid, "and not written")
end
test_attach_refuses_a_cycle()

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
  assert(verbs.cmd_move(s, pulled[1], "plan", nil, 0, false, "") == 0,
    "a return is never refused")
  assert(check.must(store.load(s, pulled[1])).claim == "",
    "and a return clears the claim")
end
test_wip_limits_bind_arrivals_but_never_returns()

-- Landing order is a board fact like any other: one verb, one commit,
-- and refusals where hand-editing the field wrote nonsense.
local function test_block_records_landing_order_and_refuses_nonsense()
  local s = init_state_repo("block")
  local goal, first = root_with_leaf(s)
  local second = file_item(s, "the slice that waits", goal, false)
  assert(verbs.cmd_block(s, second, first, false, "") ~= 0,
    "a block with no reason is refused")
  assert(verbs.cmd_block(s, second, first, false, "first lands the API") == 0)
  local waited = check.must(store.load(s, second))
  assert(#waited.blocked_by == 1, "the blocker is recorded")
  assert(waited.block_reason[first] == "first lands the API",
    "the reason rides on the edge")
  assert(verbs.cmd_block(s, second, first, false, "again") ~= 0,
    "recording it twice records nothing")
  assert(verbs.cmd_block(s, second, second, false, "self") ~= 0,
    "an item cannot block itself")
  assert(verbs.cmd_block(s, first, second, false, "reverse") ~= 0,
    "and the reverse edge would deadlock both")
  assert(#check.must(store.load(s, first)).blocked_by == 0,
    "the refused edge is not written")
  assert(verbs.cmd_block(s, second, first, true, "") == 0, "unblock drops it")
  local freed = check.must(store.load(s, second))
  assert(#freed.blocked_by == 0, "leaving none")
  assert(freed.block_reason[first] == nil, "the reason goes with the edge")
  assert(verbs.cmd_block(s, second, first, true, "") ~= 0,
    "and dropping what is not there is refused")
end
test_block_records_landing_order_and_refuses_nonsense()

-- A blocker id with no item behind it never blocks, so it reads as
-- "sequenced" and pulls anyway. The ready bar is where that is caught.
local function test_ready_bar_names_a_blocker_that_is_not_an_item()
  local s = init_state_repo("dangling")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  local it = check.must(store.load(s, leaf))
  it.blocked_by = {"3HyArM3A3zHuRxn3VYCvKmUZ7KW"}
  assert(store.save(s, it, "hand-edited blocker"))
  local problems = gate.ready_problems(s, check.must(store.load(s, leaf)),
    check.must(store.list(s)))
  assert(#problems == 1 and problems[1]:find("not an item", 1, true),
    "the bar names it: " .. table.concat(problems, "; "))
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") ~= 0,
    "and the promotion is refused")
end
test_ready_bar_names_a_blocker_that_is_not_an_item()

-- --force is for repair, and a repair the log cannot explain is
-- indistinguishable from ordinary flow.
local function test_force_states_its_reason_and_the_log_keeps_it()
  local s = init_state_repo("why")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, true, "") ~= 0,
    "a bare --force is refused")
  assert(check.must(store.load(s, leaf)).phase == "plan", "and changes nothing")
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, true,
      "repairing a spec the importer mangled") == 0)
  local events = check.must(store.history(s, leaf))
  assert(events[1].subject:find("forced: repairing a spec", 1, true),
    "the reason rides the commit: " .. events[1].subject)
end
test_force_states_its_reason_and_the_log_keeps_it()

-- A blocker stated in prose and nowhere else sequences nothing: `next`
-- reads the field, not the sidecar.
local function test_ready_bar_wants_a_prose_blocker_mirrored_in_the_field()
  local s = init_state_repo("mirror")
  local goal, leaf = root_with_leaf(s)
  local blocker = file_item(s, "the one that lands first", goal, false)
  local path = fs.join(tmpdir, "blocked-spec.md")
  assert(fs.write(path, (READY_SPEC:gsub("Nothing needed.",
          "Blocked by: the slice above."))))
  assert(verbs.cmd_spec(s, leaf, path) == 0)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") ~= 0,
    "prose claims a blocker the field does not carry")
  assert(verbs.cmd_block(s, leaf, blocker, false, "sequenced behind it") == 0)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0,
    "recording it satisfies the bar")
end
test_ready_bar_wants_a_prose_blocker_mirrored_in_the_field()

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
  assert(verbs.cmd_new(s, "a cosmopolitan-side slice", goal, nil,
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

-- Fill plan to its limit under `goal`, returning the leaves filed.
local function fill_plan(s: store.Store, goal: string): {string}
  local out: {string} = {}
  while occupancy(s, "plan") < flow.LIMITS["plan"] do
    out[#out + 1] = file_item(s, ("filler %d"):format(#out + 1), goal, false)
  end
  return out
end

-- Decomposing a workable leaf frees the slot it fills: the parent
-- leaves the phase in the same commit the child enters it. The limit
-- exists to force draining, so refusing the drain itself would be the
-- gate working against its own purpose.
local function test_a_full_plan_admits_a_net_zero_decomposition()
  local s = init_state_repo("netzero")
  local goal, leaf = root_with_leaf(s)
  local _filled = fill_plan(s, goal)
  local before = occupancy(s, "plan")
  assert(before == flow.LIMITS["plan"], "plan starts full: " .. before)
  local kid = file_item(s, "a sub-slice", leaf, false)
  assert(occupancy(s, "plan") == before,
    ("decomposition is net-zero: %d -> %d"):format(before,
      occupancy(s, "plan")))
  assert(check.must(store.load(s, leaf)).phase == "",
    "the parent left the board in the same commit")
  assert(check.must(store.load(s, kid)).phase == "plan", "the child took its slot")
end
test_a_full_plan_admits_a_net_zero_decomposition()

-- A container is already off the board, so a second child frees
-- nothing and is an ordinary arrival the full column refuses.
local function test_a_full_plan_still_refuses_a_containers_next_child()
  local s = init_state_repo("container")
  local goal, leaf = root_with_leaf(s)
  local _filled = fill_plan(s, goal)
  local _first = file_item(s, "the first child", leaf, false)
  local before = occupancy(s, "plan")
  assert(verbs.cmd_new(s, "the second child", leaf, nil, "", false, "") ~= 0,
    "plan is full and this arrival frees no slot")
  assert(occupancy(s, "plan") == before, "and nothing was written")
end
test_a_full_plan_still_refuses_a_containers_next_child()

-- A parent in a DIFFERENT phase frees a slot somewhere else, which is
-- no help to the phase being entered.
local function test_a_parent_in_another_phase_earns_no_credit()
  local s = init_state_repo("elsewhere")
  local goal, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  local _filled = fill_plan(s, goal)
  local before = occupancy(s, "plan")
  assert(verbs.cmd_new(s, "a child of a ready parent", leaf, nil, "",
      false, "") ~= 0,
    "the freed slot is ready's, and the child arrives into plan")
  assert(occupancy(s, "plan") == before, "and nothing was written")
end
test_a_parent_in_another_phase_earns_no_credit()

-- Adoption is admitted at any occupancy — triage is a decision already
-- made — so the drain of an over-bound triage queue is never refused,
-- whether what adopts the capture is a workable leaf or a container.
local function test_adoption_is_admitted_by_a_full_plan()
  local s = init_state_repo("adopt")
  local goal, leaf = root_with_leaf(s)
  local _filled = fill_plan(s, goal)
  local under_leaf = file_item(s, "a capture", "", false)
  local before = occupancy(s, "plan")
  assert(verbs.cmd_attach(s, under_leaf, leaf) == 0,
    "adopting under a workable leaf is net-zero")
  assert(occupancy(s, "plan") == before, "so the column is unchanged")
  local under_container = file_item(s, "another capture", "", false)
  assert(verbs.cmd_attach(s, under_container, leaf) == 0,
    "and adopting under the container it became is admitted too")
  assert(occupancy(s, "plan") == before + 1,
    "that one really does arrive")
end
test_adoption_is_admitted_by_a_full_plan()

-- `land` is where the merge happens, and `gitboard land` performs it
-- from the verdict and PR it reads back. An arrival carrying neither
-- is an item `next` answers `finish` for and `land` refuses forever,
-- so the arrival is what gets refused instead.
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
