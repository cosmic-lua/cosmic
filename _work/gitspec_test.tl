#!/usr/bin/env cosmic
-- The verbs that judge an item's spec sidecar: `spec` itself, whose
-- write is a compare-and-swap against the text the caller read; the
-- ready bar, which asks whether that text says enough to implement
-- from; and the evidence handover, which asks whether it carries the
-- findings it hands a reviewer. All three read the same file, so they
-- are tested together, apart from the phase crossings in
-- `_work/gitverbs_test.tl`, which judge an item's MOTION.

local check = require("cosmic.check")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local fs = require("cosmic.fs")
local store = require("_work.store")
local fixture = require("_work.fixture")
local verbs = require("_work.gitverbs")
local graph = require("_work.gitgraph")
local view = require("_work.gitview")

local tmpdir = fixture.tmpdir
local READY_SPEC < const > = fixture.READY_SPEC
local init_state_repo = fixture.init_state_repo
local init_shared = fixture.init_shared
local file_item = fixture.file_item
local commits = fixture.commits
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

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
  assert(check.must(store.load(s, leaf)).phase == "backlog", "it stayed put")
end
test_the_ready_bar_still_refuses_a_hollow_spec()

-- Re-running a mutation that records the same values says so.
local function test_a_no_op_mutation_is_named()
  local s = init_state_repo("noop")
  local _, leaf = root_with_leaf(s)
  local path = fs.join(tmpdir, "ready-spec.md")
  assert(fs.write(path, READY_SPEC))
  assert(verbs.cmd_spec(s, leaf, path) == 0)
  assert(verbs.cmd_spec(s, leaf, path, path) ~= 0,
    "the same spec twice records nothing the second time")
end
test_a_no_op_mutation_is_named()

-- One markdown file under tmpdir, for the spec tests below.
local function spec_file(name: string, body: string): string
  local path = fs.join(tmpdir, name .. ".md")
  assert(fs.write(path, body))
  return path
end

-- `spec` replaces the WHOLE sidecar, so a write naming no base is one
-- that cannot say what it read. Refused, with nothing recorded.
local function test_spec_refuses_a_write_with_no_base()
  local s = init_state_repo("nobase")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_spec(s, leaf, spec_file("nobase-first", READY_SPEC)) == 0,
    "the first spec has nothing to overwrite, so it needs no base")
  local second = spec_file("nobase-second",
    (READY_SPEC:gsub("Nothing needed.", "Rewritten.")))
  local before = commits(s)
  assert(verbs.cmd_spec(s, leaf, second) ~= 0,
    "a second write with no base is last-write-wins")
  assert(store.read_spec(s, leaf) == READY_SPEC, "so the first text stands")
  assert(commits(s) == before, "and nothing was committed")
end
test_spec_refuses_a_write_with_no_base()

-- The base is the text the caller READ. One a later writer already
-- replaced is the concurrent refinement this catches; re-reading the
-- sidecar makes the very same write land.
local function test_spec_refuses_a_stale_base()
  local s = init_state_repo("stalebase")
  local _, leaf = root_with_leaf(s)
  local first = spec_file("stale-first", READY_SPEC)
  assert(verbs.cmd_spec(s, leaf, first) == 0)
  local second = spec_file("stale-second",
    (READY_SPEC:gsub("Nothing needed.", "First edit.")))
  assert(verbs.cmd_spec(s, leaf, second, first) == 0, "the base it read")
  local third = spec_file("stale-third",
    (READY_SPEC:gsub("Nothing needed.", "Second edit.")))
  assert(verbs.cmd_spec(s, leaf, third, first) ~= 0,
    "a base the second write already replaced is stale")
  assert(verbs.cmd_spec(s, leaf, third, fs.join(tmpdir, "gone.md")) ~= 0,
    "and an unreadable base is refused, not taken as empty")
  local current = spec_file("stale-current", store.read_spec(s, leaf))
  assert(verbs.cmd_spec(s, leaf, third, current) == 0,
    "re-reading the sidecar makes the same write land")
  assert(store.read_spec(s, leaf):find("Second edit.", 1, true) ~= nil,
    "carrying the text it meant to write")
end
test_spec_refuses_a_stale_base()

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
  assert(graph.cmd_block(s, leaf, blocker, false, "sequenced behind it") == 0)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0,
    "recording it satisfies the bar")
end
test_ready_bar_wants_a_prose_blocker_mirrored_in_the_field()

-- A research slice's deliverable is recorded findings, not a diff, so
-- `--evidence` is the handover that carries it. The flag is required
-- rather than inferred from a missing --pr: a code slice whose builder
-- forgot the number must still be refused, or a reviewer gets an item
-- that says "judge something" and names nothing.
local function test_check_takes_an_evidence_handover_only_when_asked()
  local s = init_state_repo("evidence")
  local _, leaf = root_with_leaf(s)
  local path = fs.join(tmpdir, "evidence-spec.md")
  assert(fs.write(path, READY_SPEC .. "## Result\nSix runs, both ways.\n"))
  assert(verbs.cmd_spec(s, leaf, path) == 0)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "") ~= 0,
    "no PR and no flag is still refused")
  assert(check.must(store.load(s, leaf)).phase == "do", "and does not move")
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "", true) == 0,
    "--evidence hands the findings over")
  local handed = check.must(store.load(s, leaf))
  assert(handed.phase == "check", "it reaches the reviewer")
  assert(handed.pr == 0, "carrying no PR")
  assert(handed.claim == "session-a", "and still naming its builder")
end
test_check_takes_an_evidence_handover_only_when_asked()

-- What `--evidence` points the reviewer at is the spec's `## Result`
-- section, so a handover with nothing written there hands over nothing
-- and is refused on that ground instead of the PR one.
local function test_an_evidence_handover_carries_a_result_section()
  local s = init_state_repo("evidence-empty")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "", true) ~= 0,
    "a spec with no ## Result section has no findings to judge")
  assert(check.must(store.load(s, leaf)).phase == "do", "and does not move")
  local path = spec_file("hollow-result",
    READY_SPEC .. "## Result\n\n## Notes\nlater\n")
  assert(verbs.cmd_spec(s, leaf, path, spec_file("hollow-base", READY_SPEC)) == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "", true) ~= 0,
    "nor does a heading with nothing under it")
end
test_an_evidence_handover_carries_a_result_section()

-- The gate that asks GitHub whether a request is worth a reviewer's
-- time has a PR to ask about only when one is named. An evidence
-- handover names none, so asking is a question about PR #0 and its
-- 404 refuses the handover the flag exists to allow. Written against
-- a SHARED fixture on purpose: a local-only store has no origin, so
-- `handover_refusal` returns at its first line and this whole class of
-- gate is inert. The shared fixture's origin is a local path, which
-- `gh.tl` rejects before any HTTP — so this reaches the gate without
-- reaching the network.
local function test_an_evidence_handover_asks_github_nothing()
  local a = init_shared("evidence-origin")
  local _, leaf = root_with_leaf(a)
  local path = fs.join(tmpdir, "evidence-origin-spec.md")
  assert(fs.write(path, READY_SPEC .. "## Result\nMeasured, twice.\n"))
  assert(verbs.cmd_spec(a, leaf, path) == 0)
  assert(verbs.cmd_move(a, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(a, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(a, leaf, "check", nil, 0, false, "", true) == 0,
    "an evidence handover reaches the reviewer over a board with an origin")
  local handed = check.must(store.load(a, leaf))
  assert(handed.phase == "check", "it moved: " .. tostring(handed.phase))
  assert(handed.pr == 0, "carrying no PR")
end
test_an_evidence_handover_asks_github_nothing()
