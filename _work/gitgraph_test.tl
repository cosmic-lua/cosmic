#!/usr/bin/env cosmic
-- The graph verbs against scratch state repositories: filing an item,
-- the parent edge and the blocker edge, their refusals, and the
-- properties that hold across such a mutation — one commit per
-- change, and locks that cannot outlive the decomposition that made
-- their holder a container.

local check = require("cosmic.check")
local cmp = require("_work.gitcompare")
local decision = require("_work.decision")
local flow = require("_work.flow")
local gitboard = require("_work.gitboard")
local intake = require("_work.intake")
local prio = require("_work.priority")
local publish = require("_work.publish")
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

-- Re-parenting after a lost push race: `attach` has no WIP gate up
-- front — triage is a decision already made — so after the race the
-- RE-RUN lands exactly as the first run would have.
local function test_a_reparent_survives_a_rebase()
  local a, b = init_shared("attach-race")
  local goal, leaf = root_with_leaf(a)
  local other = file_item(a, "another leaf", goal)
  assert(publish.sync(b))
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

-- Attaching under one's own descendant would make a cycle.
local function test_attach_refuses_a_cycle()
  local s = init_state_repo("cycle")
  local _, leaf = root_with_leaf(s)
  local kid = file_item(s, "a child", leaf)
  assert(graph.cmd_attach(s, leaf, kid) ~= 0, "a cycle must be refused")
  assert(check.must(store.load(s, leaf)).parent ~= kid, "and not written")
end

-- Attaching a pair already attached asks for the state the board already
-- has — a no-op that succeeds, printing store's own line, not a misleading
-- "now under" as though a fresh edge had landed.
local function test_attach_of_an_already_attached_pair_is_a_noop_success()
  local s = init_state_repo("attach-noop")
  local goal, leaf = root_with_leaf(s)
  local before, seen, old_print = commits(s), "", _G.print
  _G.print = function(msg: any) seen = tostring(msg) end
  local code = graph.cmd_attach(s, leaf, goal)
  _G.print = old_print
  assert(code == 0 and commits(s) == before and seen:find("nothing to record", 1, true) ~= nil, seen)
end

--- Run graph.cmd_block and capture exactly what it prints via print() --
--- the same swap-and-restore pattern verdict_and_capture in
--- gitverdict_test.tl uses -- so a test can pin the exact line printed,
--- not just the exit code (an edge already present is a no-op SUCCESS
--- that prints `store`'s own "nothing to record" line, and only the
--- text says so -- the exit code alone reads the same as any other
--- success).
--- @param s store.Store The store
--- @param id string The waiting item
--- @param blocker string The item it waits on
--- @param remove boolean True to drop the blocker instead of adding it
--- @param reason string What concretely cannot proceed; required to add
--- @return integer cmd_block's exit code
--- @return string Every print()'d line, newline-joined
local function block_and_capture(s: store.Store, id: string, blocker: string,
    remove: boolean, reason: string): integer, string
  local old_print = _G.print
  local lines: {string} = {}
  _G.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local ok, result = pcall(graph.cmd_block, s, id, blocker, remove, reason)
  _G.print = old_print
  if not ok then
    error(result, 0)
  end
  return result, table.concat(lines, "\n")
end

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
  local before_noop = commits(s)
  local noop_code, noop_line = block_and_capture(s, second, first, false,
    "first lands the API")
  assert(noop_code == 0, "an identical reason is a no-op, not a refusal")
  assert(noop_line:find("nothing to record", 1, true) ~= nil,
    "prints store's own no-op line: " .. noop_line)
  assert(commits(s) == before_noop, "a no-op writes no commit")
  local unchanged = check.must(store.load(s, second))
  assert(#unchanged.blocked_by == 1, "the blocker list is untouched")
  assert(unchanged.block_reason[first] == "first lands the API",
    "the reason is untouched")
  local before_update = commits(s)
  assert(graph.cmd_block(s, second, first, false, "the API grew a v2 path") == 0,
    "a different reason updates the edge instead of refusing")
  assert(commits(s) == before_update + 1, "the update is one commit")
  local updated = check.must(store.load(s, second))
  assert(#updated.blocked_by == 1, "blocked_by is untouched by the update")
  assert(updated.blocked_by[1] == first, "still the same blocker")
  assert(updated.block_reason[first] == "the API grew a v2 path",
    "the reason was replaced")
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

-- `block` is a pure graph edit, and its verdict line carries the
-- block-first procedure's two edges: a claim on the waiting item
-- stands through it (releasing is `drop`'s, said on the line), and an
-- UNPLACED blocker still wires — the edge is real — but the line
-- warns, because `take` refuses unplaced work, so the chain would
-- park behind a question nobody can pull.
local function test_block_keeps_the_claim_and_warns_on_an_unplaced_blocker()
  local s = init_state_repo("block-guidance")
  local goal, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  local placed = file_item(s, "the placed question", goal)
  local code, line = block_and_capture(s, leaf, placed,
    false, "the decision is open")
  assert(code == 0, "blocking a claimed item is not refused")
  assert(line:find("`drop` releases it", 1, true) ~= nil,
    "a claimed item's line points the release at drop: " .. line)
  assert(line:find("UNPLACED", 1, true) == nil,
    "a placed blocker earns no placement warning: " .. line)
  assert(check.must(store.load(s, leaf)).claim == "session-a",
    "the claim stands through the block — a graph edit moves no lease")
  local stray = file_item(s, "an unplaced question", "")
  local code2, line2 = block_and_capture(s, leaf, stray,
    false, "awaiting a decision nobody has placed")
  assert(code2 == 0,
    "an unplaced blocker still wires — the warning is advisory")
  assert(line2:find("UNPLACED", 1, true) ~= nil,
    "the line warns that the chain parks behind unplaced work: " .. line2)
  assert(#check.must(store.load(s, leaf)).blocked_by == 2,
    "both edges stand")
end

-- `new --repo` scopes the item's PR to a foreign repo; the field is
-- what makes cross-repo work (a cosmopolitan fix serving a cosmic
-- goal) visible instead of a URL buried in prose. Bare (no --parent),
-- --repo is refused with the two ways out: file it under an outcome,
-- or add the repo after through `attach` then `set --repo`.
local function test_new_repo_lands_the_field()
  local s = init_state_repo("cross-repo")
  local goal = file_item(s, "an outcome", "")
  local seen, old_print = "", _G.print
  _G.print = function(msg: any) seen = tostring(msg) end
  local refused = graph.cmd_new(s, "a slice", "", nil, "whilp/cosmopolitan")
  _G.print = old_print
  assert(refused ~= 0 and seen:find("--parent ID", 1, true) and seen:find("set ID --repo", 1, true), seen)
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

-- A title carrying a newline lands in the item file and `show` then
-- renders the second line as its own board row, indistinguishable
-- from a real item — the shape check lives in `item.problems`, the
-- one place both `new` and `set --title` route their finished item
-- through, so this refusal is the same one `set` gets below.
local function test_new_refuses_a_multiline_or_padded_title()
  local s = init_state_repo("new-hostile-title")
  local before = check.must(store.list(s))
  assert(graph.cmd_new(s, "innocent\nfake line", "", nil, "") ~= 0,
    "a newline in the title is refused")
  assert(graph.cmd_new(s, "  padded  ", "", nil, "") ~= 0,
    "leading/trailing whitespace in the title is refused")
  local after = check.must(store.list(s))
  assert(#after == #before, "neither refusal filed an item")
end

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

-- `set` repairs the three destination facts a refinement can outgrow:
-- title, repo, base. Each round-trips through a real store, and the
-- commit subject names WHICH fields moved, never their values.
local function test_set_round_trips_title_repo_and_base()
  local s = init_state_repo("set-round-trip")
  local goal, leaf = root_with_leaf(s)
  assert(graph.cmd_set(s, leaf, "a truer title", "whilp/cosmopolitan",
      "release") == 0)
  local it = check.must(store.load(s, leaf))
  assert(it.title == "a truer title", "title landed: " .. it.title)
  assert(it.repo == "whilp/cosmopolitan", "repo landed: " .. it.repo)
  assert(it.base == "release", "base landed: " .. it.base)
  local events = check.must(publish.history(s, leaf))
  assert(events[1].subject:match("^set %w%w%w%w%w%w%w%w title repo base$")
    ~= nil, "the subject names the fields, canonically ordered, no "
    .. "values: " .. events[1].subject)
  assert(not events[1].subject:find("a truer title", 1, true),
    "the title text stays out of the subject: " .. events[1].subject)

  -- Setting only one field leaves the others untouched.
  assert(graph.cmd_set(s, leaf, nil, nil, "main") == 0)
  local moved = check.must(store.load(s, leaf))
  assert(moved.base == "main" and moved.title == "a truer title"
    and moved.repo == "whilp/cosmopolitan",
    "an unset flag leaves its field alone")
  assert(goal ~= "", "root filed for the fixture")
end

-- The already-recorded case: setting a field to the value it already
-- holds asks for the state the board already has — a no-op that
-- succeeds, not a refusal, printing `store`'s own no-op line.
local function test_set_the_same_value_is_a_noop_success()
  local s = init_state_repo("set-noop")
  local _, leaf = root_with_leaf(s)
  assert(graph.cmd_set(s, leaf, "a truer title", nil, nil) == 0)
  local before = commits(s)
  local old_print = _G.print
  local lines: {string} = {}
  _G.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local code = graph.cmd_set(s, leaf, "a truer title", nil, nil)
  _G.print = old_print
  assert(code == 0, "the same title again is a no-op, not a refusal")
  assert(table.concat(lines, "\n"):find("nothing to record", 1, true) ~= nil,
    "prints store's own no-op line: " .. table.concat(lines, "\n"))
  assert(commits(s) == before, "a no-op writes no commit")
end

-- No flags at all names nothing to repair.
local function test_set_with_no_flags_is_refused()
  local s = init_state_repo("set-empty")
  local _, leaf = root_with_leaf(s)
  assert(graph.cmd_set(s, leaf, nil, nil, nil) ~= 0,
    "set needs at least one field")
end

-- An explicit empty --repo/--base would silently CLEAR the field —
-- an un-gating path (an empty base means "ungated") with no flag
-- naming what it just did. Refuse it instead; the way to change the
-- field stays `set --repo/--base <value>`.
local function test_set_refuses_an_empty_repo_or_base()
  local s = init_state_repo("set-empty-clear")
  local _, leaf = root_with_leaf(s)
  assert(graph.cmd_set(s, leaf, "a truer title", "whilp/cosmopolitan",
      "release") == 0)
  assert(graph.cmd_set(s, leaf, nil, "", nil) ~= 0,
    "an empty --repo is refused, not treated as a clear")
  assert(graph.cmd_set(s, leaf, nil, nil, "") ~= 0,
    "an empty --base is refused, not treated as a clear")
  local it = check.must(store.load(s, leaf))
  assert(it.repo == "whilp/cosmopolitan" and it.base == "release",
    "neither refusal cleared the field")
end

-- `set --title` is the other entry point that writes a title; the
-- same shape check refuses it there, and nothing gets overwritten.
local function test_set_refuses_a_multiline_or_padded_title()
  local s = init_state_repo("set-hostile-title")
  local _, leaf = root_with_leaf(s)
  local before = check.must(store.load(s, leaf))
  assert(graph.cmd_set(s, leaf, "innocent\nfake line", nil, nil) ~= 0,
    "a newline in the title is refused")
  assert(graph.cmd_set(s, leaf, "  padded  ", nil, nil) ~= 0,
    "leading/trailing whitespace in the title is refused")
  local after = check.must(store.load(s, leaf))
  assert(after.title == before.title,
    "neither refusal changed the stored title")
end

-- A finished item's destination facts are history, not a repair
-- target.
local function test_set_refuses_a_done_item()
  local s = init_state_repo("set-done")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_done(s, leaf, "not-planned", false, "") == 0)
  assert(graph.cmd_set(s, leaf, "a new title", nil, nil) ~= 0,
    "a done item refuses set")
  local it = check.must(store.load(s, leaf))
  assert(it.title ~= "a new title", "and nothing was written")
end

-- `set` declares only title/repo/base — every flow field (claim, pr,
-- verdict, resolution, parent, blocked_by, lane) has its own verb and
-- gate, so `set` refuses those by not declaring the flag at all: the
-- dispatcher's own unrecognized-flag error, before `cmd_set` runs.
local function test_set_refuses_an_unknown_flag()
  local s = init_state_repo("set-unknown-flag")
  local _, leaf = root_with_leaf(s)
  assert(gitboard.main("set", leaf, "--claim", "session-x",
      "--dir", s.root) ~= 0,
    "a flow field is not a set flag")
  local it = check.must(store.load(s, leaf))
  assert(it.claim == "", "nothing was written")
end

-- The wall by name: EVERY flow field — not just --claim — has its own
-- verb and gate, and `set` must refuse each as an unrecognized flag
-- rather than reach `cmd_set`'s body, which has no field to write it
-- into. Driven through the full CLI dispatch (not `graph.cmd_set`
-- directly) because the wall lives in the flag SPEC `set` declares,
-- not in `cmd_set`'s own logic. A test that only checks the exit code
-- of `--claim` alone cannot tell the dispatcher's unknown-flag
-- refusal from cmd_set's unrelated "needs at least one of --title,
-- --repo, --base" refusal — both exit nonzero — so this checks the
-- item file is untouched after every attempt too: a flag that got
-- wired AND written would leave a trace here even if some other path
-- also happened to exit nonzero.
local function test_set_refuses_every_flow_field_flag()
  local s = init_state_repo("set-flow-wall")
  local _, leaf = root_with_leaf(s)
  local before = check.must(store.load(s, leaf))
  local flow_flags: {{string, string}} = {
    {"--claim", "session-x"},
    {"--pr", "5"},
    {"--verdict", "accept"},
    {"--parent", leaf},
    {"--resolution", "completed"},
    {"--lane", "release.yml"},
  }
  for _, pair in ipairs(flow_flags) do
    local flag, value = pair[1], pair[2]
    assert(gitboard.main("set", leaf, flag, value, "--dir", s.root) ~= 0,
      flag .. " is a flow field, not a set flag")
  end
  local after = check.must(store.load(s, leaf))
  assert(after.claim == before.claim, "claim untouched: " .. after.claim)
  assert(after.pr == before.pr, "pr untouched: " .. tostring(after.pr))
  assert(after.verdict == before.verdict, "verdict untouched: " .. after.verdict)
  assert(after.parent == before.parent, "parent untouched: " .. after.parent)
  assert(after.resolution == before.resolution,
    "resolution untouched: " .. after.resolution)
  assert(after.lane == before.lane, "lane untouched: " .. after.lane)
end

-- The derived order is a closure over `beats` across EVERY item, open,
-- held or done: holding the middle of a chain A > B > C leaves A and C
-- placed and A's dominance count whole. A held root is not ended — it
-- is still listed by `flow.roots` — but intake walks past it the way
-- it walks past a root with live work, and filing evidence under it
-- clears the hold in the same commit as the child.
local function test_holding_a_root_keeps_the_order_total_and_reopens_on_evidence()
  local s = init_state_repo("hold-order")
  local a = file_item(s, "outcome A", "")
  local b = file_item(s, "outcome B", "")
  local c = file_item(s, "outcome C", "")
  assert(cmp.cmd_compare(s, a, b) == 0)
  assert(cmp.cmd_compare(s, b, c) == 0)
  local function own_of(id: string): integer
    local _, own = prio.key_of(prio.positions(check.must(store.list(s))), id)
    return own
  end
  local function offered(): decision.Action
    local all = check.must(store.list(s))
    return intake.intake_action(all, {}, flow.by_id(all), prio.positions(all))
  end
  local a_own_before = own_of(a)
  assert(a_own_before == 2, "A dominates B and C transitively: " .. a_own_before)
  assert(cmp.cmd_hold(s, b, "B's win condition verified") == 0)
  local all = check.must(store.list(s))
  local at = prio.positions(all)
  assert(prio.is_placed(at, a) and prio.is_placed(at, c),
    "holding B severs no chain: A and C keep their positions")
  assert(own_of(a) == a_own_before, "and A's dominance count is unchanged")
  local ordered, live, held = flow.roots(all)
  local listed: {string: boolean} = {}
  for _, r in ipairs(ordered) do
    listed[r.id] = true
  end
  assert(listed[a] and listed[c] and listed[b],
    "a held root is not ended, so nothing leaves the general listing")
  assert(held[b] and not held[a] and not held[c] and not live[b],
    "roots names B held, and nothing live")
  -- Intake never offers B: with A open and idle it offers A; with A
  -- held too it skips over B to C; with every root held, the fallback.
  local first = check.must(offered())
  assert(first.kind == "intake" and first.item.id == a,
    "the top-ranked idle root is offered first")
  assert(cmp.cmd_hold(s, a, "A verified") == 0)
  local second = check.must(offered())
  assert(second.kind == "intake" and second.item.id == c,
    "with A held, intake walks past held B to C")
  assert(cmp.cmd_hold(s, c, "C verified") == 0)
  local third = check.must(offered())
  assert(third.kind == "intake" and third.item == nil
    and third.reason:find("every open root has live work", 1, true) ~= nil,
    "every root held: the fallback, never B: " .. third.reason)
  -- Evidence under B reopens it in the child's own commit.
  local before = commits(s)
  assert(graph.cmd_new(s, "verification failed after all", b, nil, "") == 0)
  assert(commits(s) == before + 1,
    ("the child and the cleared hold are one commit: %d -> %d"):format(
      before, commits(s)))
  assert(not check.must(store.load(s, b)).is_held,
    "filing a child under a held root clears the hold")
  local _, live2, held2 = flow.roots(check.must(store.list(s)))
  assert(live2[b] and not held2[b], "B is live now, and no longer held")
  -- Ending that child leaves B open, idle and unheld: it is offered
  -- again with nothing further said — the skip was the hold's alone.
  local kid: string = nil
  for _, i in ipairs(check.must(store.list(s))) do
    if i.parent == b then
      kid = i.id
    end
  end
  assert(verbs.cmd_done(s, kid, "not-planned", false, "") == 0)
  local again = check.must(offered())
  assert(again.kind == "intake" and again.item.id == b,
    "an unheld idle root is offered again")
end
