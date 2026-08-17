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
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

-- Git reads a global (and system) config before it does anything, and
-- a config it cannot READ is fatal, not skipped: under the build
-- fence the home directory is outside the granted trees, so every git
-- call here — the fixtures' and the store's own — dies on
-- `unable to access '~/.gitconfig'`. Pointing this process at an
-- empty config makes the fixtures depend on no ambient state at all,
-- which is what a test of git behaviour wants regardless of the
-- fence. The store itself is deliberately NOT hermetic: a real
-- session's push needs the user's credentials and config.
local hermetic_config < const > = fs.join(tmpdir, "gitconfig-empty")
assert(fs.write(hermetic_config, ""))
assert(env.set("GIT_CONFIG_GLOBAL", hermetic_config))
assert(env.set("GIT_CONFIG_NOSYSTEM", "1"))

local READY_SPEC < const > = [[
## Goal
Serves the ranked goal above it.
## Change
Do exactly this.
## Non-goals
Not that.
## Acceptance
`cosmic --make ci`
## Enablement
Nothing needed.
]]

--- Run one git command in `cwd`, failing loudly — fixture setup.
local function git(cwd: string, argv: {string})
  local full: {string} = {"git", "-c", "user.email=test@example.com",
    "-c", "user.name=test", "-c", "core.createObject=rename"}
  for _, a in ipairs(argv) do
    full[#full + 1] = a
  end
  local r = check.must(child.run(full, {cwd = cwd}))
  assert(r.ok, "git " .. table.concat(argv, " ") .. " failed: " .. r.stderr)
end

--- A fresh local-only state repo with one seed commit.
local function init_state_repo(name: string): store.Store
  local root = fs.join(tmpdir, "verbs-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(fs.join(root, "items")))
  git(root, {"init", "-q"})
  assert(fs.write(fs.join(root, "items", ".gitkeep"), ""))
  git(root, {"add", "-A"})
  git(root, {"commit", "-q", "-m", "init"})
  return check.must(store.open(root))
end

--- A bare "remote" seeded with an empty items/ tree, plus two clones.
local function init_shared(name: string): store.Store, store.Store
  local base = fs.join(tmpdir, "verbs-shared-" .. name)
  assert(fs.remove_all(base))
  assert(fs.make_dirs(base))
  local bare = fs.join(base, "remote.git")
  git(base, {"init", "-q", "--bare", bare})
  git(bare, {"config", "core.createObject", "rename"})
  local seed = fs.join(base, "seed")
  git(base, {"clone", "-q", bare, seed})
  assert(fs.make_dirs(fs.join(seed, "items")))
  assert(fs.write(fs.join(seed, "items", ".gitkeep"), ""))
  git(seed, {"add", "-A"})
  git(seed, {"commit", "-q", "-m", "init"})
  git(seed, {"push", "-q", "origin", "HEAD"})
  local out: {store.Store} = {}
  for i = 1, 2 do
    local dir = fs.join(base, ("clone%d"):format(i))
    git(base, {"clone", "-q", bare, dir})
    git(dir, {"config", "core.createObject", "rename"})
    out[#out + 1] = check.must(store.open(dir))
  end
  return out[1], out[2]
end

--- File an item through `new` and return its id. A KSUID orders by
--- its one-second timestamp, so items minted inside the same second
--- sort by their random half — "the newest item" is not something a
--- test can read off the sorted list. The set difference is.
local function file_item(s: store.Store, title: string, parent: string,
    rank: integer, force: boolean): string
  local before: {string: boolean} = {}
  for _, i in ipairs(check.must(store.list(s))) do
    before[i.id] = true
  end
  assert(verbs.cmd_new(s, title, parent, rank, nil, force) == 0,
    "new should be accepted: " .. title)
  for _, i in ipairs(check.must(store.list(s))) do
    if not before[i.id] then
      return i.id
    end
  end
  error("new filed nothing: " .. title)
end

--- How many commits a store's checkout carries.
local function commits(s: store.Store): integer
  local r = check.must(child.run({"git", "rev-list", "--count", "HEAD"},
      {cwd = s.root}))
  assert(r.ok, "git rev-list failed: " .. r.stderr)
  return math.tointeger(tonumber((r.stdout:gsub("%s+$", "")))) or -1
end

--- A spec sidecar meeting the ready bar, through the spec verb.
local function give_spec(s: store.Store, id: string)
  local path = fs.join(tmpdir, "ready-spec.md")
  assert(fs.write(path, READY_SPEC))
  assert(verbs.cmd_spec(s, id, path) == 0, "spec should be accepted")
end

--- A goal with one workable leaf under it, both filed through `new`.
local function goal_with_leaf(s: store.Store): string, string
  local goal = file_item(s, "a ranked goal", "", 1, false)
  return goal, file_item(s, "a workable slice", goal, 0, false)
end

-- A decomposition writes the child AND the parent it de-phases, and
-- they are one commit: half of it reaching the board would leave a
-- parent off the board with nothing decomposing it.
local function test_decomposition_is_one_commit()
  local s = init_state_repo("decompose")
  local _, leaf = goal_with_leaf(s)
  local before = commits(s)
  local _kid = file_item(s, "a sub-slice", leaf, 0, false)
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
  local goal, leaf = goal_with_leaf(a)
  local last_filler = ""
  for i = 1, 9 do
    last_filler = file_item(a, ("filler %d"):format(i), leaf, 0, false)
  end
  -- The leaf is a container now; plan holds its 9 children. The other
  -- clone fills plan past the limit before this one files a tenth, so
  -- the tenth loses the race at the merged state, not locally.
  assert(store.sync(b))
  for i = 1, 5 do
    assert(verbs.cmd_new(b, ("theirs %d"):format(i), goal, 0, nil, true) == 0)
  end
  local phased = check.must(store.load(a, last_filler))
  assert(phased.phase == "plan", "the parent-to-be starts on the board")
  assert(verbs.cmd_new(a, "the refused child", phased.id, 0, nil, false) ~= 0,
    "filing under a full plan must be refused after the rebase")
  local after = check.must(store.load(a, phased.id))
  assert(after.phase == "plan",
    "a refused filing leaves its parent on the board: " .. after.phase)
  local r = check.must(child.run({"git", "status", "--porcelain"},
      {cwd = a.root}))
  assert((r.stdout:gsub("%s+$", "")) == "",
    "the refusal leaves no stray change: " .. r.stdout)
end
test_a_refused_decomposition_leaves_the_parent_phased()

-- The ready bar judges the item being promoted. Another item's broken
-- chain is board health, reported by `status`, never a refusal of a
-- promotion that has nothing to do with it.
local function test_the_ready_bar_is_the_items_own()
  local s = init_state_repo("readybar")
  local _, leaf = goal_with_leaf(s)
  give_spec(s, leaf)
  -- An unrelated broken chain: work under an unranked root.
  local finding = file_item(s, "a finding", "", 0, false)
  local _stray = file_item(s, "work under it", finding, 0, false)
  local all = check.must(store.list(s))
  assert(#flow.trace_problems(all) > 0, "the board does have a problem")
  assert(verbs.cmd_check(s, leaf) == 0,
    "a sound item meets the bar while another item is broken")
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false) == 0,
    "and it may be promoted")
  assert(check.must(store.load(s, leaf)).phase == "ready", "it moved")
end
test_the_ready_bar_is_the_items_own()

-- A hollow spec still refuses, naming the sections it lacks.
local function test_the_ready_bar_still_refuses_a_hollow_spec()
  local s = init_state_repo("hollow")
  local _, leaf = goal_with_leaf(s)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false) ~= 0,
    "no spec, no ready")
  assert(check.must(store.load(s, leaf)).phase == "plan", "it stayed put")
end
test_the_ready_bar_still_refuses_a_hollow_spec()

-- Closing the last child hands the board back to the container: the
-- planner verifies the outcome the children were meant to deliver.
local function test_done_returns_a_finished_container_to_plan()
  local s = init_state_repo("return")
  local _, leaf = goal_with_leaf(s)
  local kid = file_item(s, "only child", leaf, 0, false)
  assert(check.must(store.load(s, leaf)).phase == "", "the parent stepped off")
  local before = commits(s)
  assert(verbs.cmd_done(s, kid, "completed", false) == 0)
  assert(commits(s) == before + 1, "the close and the return are one commit")
  assert(check.must(store.load(s, leaf)).phase == "plan",
    "its last child closed, so the container returns to plan")
  local all = check.must(store.list(s))
  assert(#flow.trace_problems(all) == 0,
    "and nothing is left off the board: "
    .. table.concat(flow.trace_problems(all), "; "))
end
test_done_returns_a_finished_container_to_plan()

-- A container with children left open stays off the board.
local function test_done_leaves_a_still_decomposing_container_alone()
  local s = init_state_repo("stillbusy")
  local _, leaf = goal_with_leaf(s)
  local first = file_item(s, "first child", leaf, 0, false)
  local _second = file_item(s, "second child", leaf, 0, false)
  assert(verbs.cmd_done(s, first, "completed", false) == 0)
  assert(check.must(store.load(s, leaf)).phase == "",
    "one child still open: the container keeps decomposing")
end
test_done_leaves_a_still_decomposing_container_alone()

-- Re-running a mutation that records the same values says so.
local function test_a_no_op_mutation_is_named()
  local s = init_state_repo("noop")
  local _, leaf = goal_with_leaf(s)
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
  local _, leaf = goal_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false) == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false) == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 4242, false) == 0)
  local got = check.must(store.load(s, leaf))
  assert(got.pr == 4242, "the PR rides the move into check: " .. got.pr)
  assert(got.claim == "session-a", "the claim survives it")
end
test_move_records_the_pr()

-- Attaching under one's own descendant would make a cycle.
local function test_attach_refuses_a_cycle()
  local s = init_state_repo("cycle")
  local _, leaf = goal_with_leaf(s)
  local kid = file_item(s, "a child", leaf, 0, false)
  assert(verbs.cmd_attach(s, leaf, kid) ~= 0, "a cycle must be refused")
  assert(check.must(store.load(s, leaf)).parent ~= kid, "and not written")
end
test_attach_refuses_a_cycle()

-- The WIP limit refuses an arrival; a return is admitted over it.
local function test_wip_limits_bind_arrivals_but_never_returns()
  local s = init_state_repo("wip")
  local goal = ""
  local first = ""
  goal, first = goal_with_leaf(s)
  give_spec(s, first)
  assert(verbs.cmd_move(s, first, "ready", nil, 0, false) == 0)
  assert(verbs.cmd_move(s, first, "do", "session-a", 0, false) == 0)
  local pulled: {string} = {first}
  for i = 2, flow.LIMITS["do"] do
    local id = file_item(s, ("slice %d"):format(i), goal, 0, false)
    give_spec(s, id)
    assert(verbs.cmd_move(s, id, "ready", nil, 0, false) == 0)
    assert(verbs.cmd_move(s, id, "do", "session-a", 0, false) == 0)
    pulled[#pulled + 1] = id
  end
  local extra = file_item(s, "one too many", goal, 0, false)
  give_spec(s, extra)
  assert(verbs.cmd_move(s, extra, "ready", nil, 0, false) == 0)
  assert(verbs.cmd_move(s, extra, "do", "session-b", 0, false) ~= 0,
    "do is full: the arrival queues")
  assert(check.must(store.load(s, extra)).phase == "ready", "it stayed put")
  assert(verbs.cmd_move(s, pulled[1], "plan", nil, 0, false) == 0,
    "a return is never refused")
  assert(check.must(store.load(s, pulled[1])).claim == "",
    "and a return clears the claim")
end
test_wip_limits_bind_arrivals_but_never_returns()

-- `check` means "awaiting a planner verdict", so it is the one phase
-- a verdict may end: judging from anywhere else would carry unreviewed
-- work into land past every gate between them.
local function test_verdict_judges_only_what_is_in_check()
  local s = init_state_repo("verdict-phase")
  local _, leaf = goal_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_verdict(s, leaf, "accept", 0, "abc1234") ~= 0,
    "a plan item has not been reviewed")
  assert(check.must(store.load(s, leaf)).phase == "plan", "and did not move")
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false) == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false) == 0)
  assert(verbs.cmd_verdict(s, leaf, "accept", 7, "abc1234") ~= 0,
    "nor has an item still being worked")
  assert(verbs.cmd_move(s, leaf, "check", nil, 7, false) == 0)
  assert(verbs.cmd_verdict(s, leaf, "accept", 7, "abc1234") == 0,
    "from check it lands")
  assert(check.must(store.load(s, leaf)).phase == "land", "in land")
end
test_verdict_judges_only_what_is_in_check()

-- The reviewer follows the pr field to the diff, and so does the
-- landing step that reads it back, so the handover must name one.
local function test_check_refuses_a_handover_with_no_pr()
  local s = init_state_repo("check-pr")
  local _, leaf = goal_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false) == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false) == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false) ~= 0,
    "a handover naming no PR is refused")
  assert(check.must(store.load(s, leaf)).phase == "do", "and does not move")
  assert(verbs.cmd_move(s, leaf, "check", nil, 99, false) == 0)
  -- Rework returns to `do` and comes back on the SAME PR, already
  -- recorded, so the second handover needs no --pr of its own.
  assert(verbs.cmd_verdict(s, leaf, "request changes", 0, "abc1234") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false) == 0,
    "the recorded PR carries the rework back")
end
test_check_refuses_a_handover_with_no_pr()

-- Landing order is a board fact like any other: one verb, one commit,
-- and refusals where hand-editing the field wrote nonsense.
local function test_block_records_landing_order_and_refuses_nonsense()
  local s = init_state_repo("block")
  local goal, first = goal_with_leaf(s)
  local second = file_item(s, "the slice that waits", goal, 0, false)
  assert(verbs.cmd_block(s, second, first, false) == 0)
  assert(#check.must(store.load(s, second)).blocked_by == 1,
    "the blocker is recorded")
  assert(verbs.cmd_block(s, second, first, false) ~= 0,
    "recording it twice records nothing")
  assert(verbs.cmd_block(s, second, second, false) ~= 0,
    "an item cannot block itself")
  assert(verbs.cmd_block(s, first, second, false) ~= 0,
    "and the reverse edge would deadlock both")
  assert(#check.must(store.load(s, first)).blocked_by == 0,
    "the refused edge is not written")
  assert(verbs.cmd_block(s, second, first, true) == 0, "unblock drops it")
  assert(#check.must(store.load(s, second)).blocked_by == 0, "leaving none")
  assert(verbs.cmd_block(s, second, first, true) ~= 0,
    "and dropping what is not there is refused")
end
test_block_records_landing_order_and_refuses_nonsense()

-- A blocker id with no item behind it never blocks, so it reads as
-- "sequenced" and pulls anyway. The ready bar is where that is caught.
local function test_ready_bar_names_a_blocker_that_is_not_an_item()
  local s = init_state_repo("dangling")
  local _, leaf = goal_with_leaf(s)
  give_spec(s, leaf)
  local it = check.must(store.load(s, leaf))
  it.blocked_by = {"3HyArM3A3zHuRxn3VYCvKmUZ7KW"}
  assert(store.save(s, it, "hand-edited blocker"))
  local problems = gate.ready_problems(s, check.must(store.load(s, leaf)),
    check.must(store.list(s)))
  assert(#problems == 1 and problems[1]:find("not an item", 1, true),
    "the bar names it: " .. table.concat(problems, "; "))
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false) ~= 0,
    "and the promotion is refused")
end
test_ready_bar_names_a_blocker_that_is_not_an_item()
