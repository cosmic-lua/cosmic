#!/usr/bin/env cosmic
-- The verbs that judge an item's spec sidecar: `spec` itself, whose
-- write is a compare-and-swap against the text the caller read, and
-- the spec bar, which asks whether that text says enough to implement
-- from. Both read the same file, so they are tested together, apart
-- from the state verbs in `_work/gitverbs_test.tl`, which judge an
-- item's MOTION.

local check = require("cosmic.check")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local fs = require("cosmic.fs")
local publish = require("_work.publish")
local store = require("_work.store")
local fixture = require("_work.fixture")
local verbs = require("_work.gitverbs")
local graph = require("_work.gitgraph")
local view = require("_work.gitview")

local tmpdir = fixture.tmpdir
local READY_SPEC < const > = fixture.READY_SPEC
local init_state_repo = fixture.init_state_repo
local file_item = fixture.file_item
local commits = fixture.commits
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

-- The spec bar judges the item being taken. Another item's broken
-- chain is board health, reported by `status`, never a refusal of a
-- take that has nothing to do with it.
local function test_the_spec_bar_is_the_items_own()
  local s = init_state_repo("readybar")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  -- An unrelated broken chain: work under a parent that is not there.
  local finding = file_item(s, "a finding", "")
  local stray = check.must(store.load(s, finding))
  stray.parent = "3HyArM3A3zHuRxn3VYCvKmUZ7KW"
  assert(store.save(s, stray, "hand-edited parent"))
  local all = check.must(store.list(s))
  assert(#flow.graph_problems(all) > 0, "the board does have a problem")
  assert(#gate.ready_problems(s, check.must(store.load(s, leaf)), all) == 0,
    "a sound item meets the bar while another item is broken")
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0,
    "and it may be taken")
  assert(check.must(store.load(s, leaf)).claim == "session-a", "it moved")
end
test_the_spec_bar_is_the_items_own()

-- A hollow spec still refuses, naming the sections it lacks.
local function test_the_spec_bar_still_refuses_a_hollow_spec()
  local s = init_state_repo("hollow")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") ~= 0,
    "no spec, no take")
  assert(check.must(store.load(s, leaf)).claim == "", "it stayed put")
end
test_the_spec_bar_still_refuses_a_hollow_spec()

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
    (READY_SPEC:gsub("Not that.", "Rewritten.")))
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
    (READY_SPEC:gsub("Not that.", "First edit.")))
  assert(verbs.cmd_spec(s, leaf, second, first) == 0, "the base it read")
  local third = spec_file("stale-third",
    (READY_SPEC:gsub("Not that.", "Second edit.")))
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
-- "sequenced" and pulls anyway. The spec bar is where that is caught.
local function test_spec_bar_names_a_blocker_that_is_not_an_item()
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
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") ~= 0,
    "and the take is refused")
end
test_spec_bar_names_a_blocker_that_is_not_an_item()

-- A real blocker refuses the take and names what to finish first;
-- recording the order is `block`'s, and the take frees when it ends.
local function test_a_recorded_blocker_sequences_the_take()
  local s = init_state_repo("mirror")
  local goal, leaf = root_with_leaf(s)
  local blocker = file_item(s, "the one that lands first", goal)
  give_spec(s, leaf)
  assert(graph.cmd_block(s, leaf, blocker, false, "sequenced behind it") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") ~= 0,
    "the recorded order holds the take")
  assert(verbs.cmd_done(s, blocker, "completed", false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0,
    "and frees it when the blocker ends")
end
test_a_recorded_blocker_sequences_the_take()

-- The reproduced incident: a foreign session silently replacing the
-- definition of work another session already built and handed to
-- review. `spec` refuses it, and nothing moves.
local function test_spec_refuses_a_foreign_live_claim()
  local s = init_state_repo("foreignspec")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "builder-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "builder-a", 7, false, "") == 0,
    "builder-a hands the build over for review")
  local before_spec = store.read_spec(s, leaf)
  local before_commits = commits(s)
  local base = spec_file("foreign-base", before_spec)
  local rewrite = spec_file("foreign-rewrite",
    (before_spec:gsub("Not that.", "Rewritten.")))
  assert(verbs.cmd_spec(s, leaf, rewrite, base, "refiner-b") ~= 0,
    "a foreign session may not redefine work another session has "
    .. "already built and handed to review")
  assert(store.read_spec(s, leaf) == before_spec, "the sidecar is untouched")
  assert(commits(s) == before_commits, "and nothing was committed")
  local it = check.must(store.load(s, leaf))
  assert(it.claim == "builder-a" and it.pr == 7, "the claim and PR stand")
end
test_spec_refuses_a_foreign_live_claim()

-- What stays legal: the claim holder rewriting their OWN item's spec
-- at any point — spec-only rework answering a bounce is a designed
-- path, not something the new gate touches.
local function test_spec_the_holders_own_rewrite_still_lands()
  local s = init_state_repo("holderspec")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "builder-a", 0, false, "") == 0)
  local base = spec_file("holder-base", store.read_spec(s, leaf))
  local rewrite = spec_file("holder-rewrite",
    (READY_SPEC:gsub("Not that.", "Reworked answering a bounce.")))
  assert(verbs.cmd_spec(s, leaf, rewrite, base, "builder-a") == 0,
    "the claim holder reworks their own spec")
  assert(store.read_spec(s, leaf):find("Reworked answering a bounce.", 1, true)
    ~= nil)
end
test_spec_the_holders_own_rewrite_still_lands()

-- A bare --force is refused: a forced mutation with no stated reason
-- is indistinguishable in the log from an ordinary one.
local function test_spec_force_needs_why()
  local s = init_state_repo("specforceonly")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "builder-a", 0, false, "") == 0)
  local before_spec = store.read_spec(s, leaf)
  local before_commits = commits(s)
  local base = spec_file("forceonly-base", before_spec)
  local rewrite = spec_file("forceonly-rewrite",
    (before_spec:gsub("Not that.", "Overridden.")))
  assert(verbs.cmd_spec(s, leaf, rewrite, base, "refiner-b", true) ~= 0,
    "--force with no --why is refused")
  assert(store.read_spec(s, leaf) == before_spec, "and nothing changed")
  assert(commits(s) == before_commits, "nothing was committed")
end
test_spec_force_needs_why()

-- --force --why overrides a foreign live claim, and the reason rides
-- the commit subject, same as take's and done's forced writes.
local function test_spec_force_and_why_overrides_a_foreign_claim()
  local s = init_state_repo("specoverride")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "builder-a", 0, false, "") == 0)
  local before_spec = store.read_spec(s, leaf)
  local base = spec_file("override-base", before_spec)
  local rewrite = spec_file("override-rewrite",
    (before_spec:gsub("Not that.", "Overridden.")))
  assert(verbs.cmd_spec(s, leaf, rewrite, base, "refiner-b", true,
      "builder-a's session died mid-build") == 0,
    "forced, with a reason, the foreign write lands")
  assert(store.read_spec(s, leaf):find("Overridden.", 1, true) ~= nil)
  local events = check.must(publish.history(s, leaf))
  assert(events[1].subject:find("forced: builder-a's session died mid-build",
      1, true), "the reason rides the commit: " .. events[1].subject)
end
test_spec_force_and_why_overrides_a_foreign_claim()

-- `spec` records who wrote it: a named session joins `it.speccers`,
-- landing in the same commit as the sidecar since `stage` always
-- writes the item file alongside a replacement spec. A second spec by
-- the same session does not duplicate the entry.
local function test_spec_records_the_speccer_in_the_same_commit()
  local s = init_state_repo("speccer")
  local _, leaf = root_with_leaf(s)
  local first = spec_file("speccer-first", READY_SPEC)
  local before = commits(s)
  assert(verbs.cmd_spec(s, leaf, first, nil, "refiner-a") == 0)
  assert(commits(s) == before + 1, "one mutation, one commit")
  local it = check.must(store.load(s, leaf))
  assert(#it.speccers == 1 and it.speccers[1] == "refiner-a",
    "the speccer is recorded")
  local shown = check.must(store.git(s, {"show", "--name-only",
        "--pretty=format:", "HEAD"}))
  assert(shown.stdout:find(fs.join("items", leaf .. ".tl"), 1, true) ~= nil
    and shown.stdout:find(fs.join("items", leaf .. ".md"), 1, true) ~= nil,
    "the item and the sidecar land in the one commit: " .. shown.stdout)

  local second = spec_file("speccer-second",
    (READY_SPEC:gsub("Not that.", "Refined again.")))
  assert(verbs.cmd_spec(s, leaf, second, first, "refiner-a") == 0)
  local again = check.must(store.load(s, leaf))
  assert(#again.speccers == 1, "the same session again does not duplicate")
end
test_spec_records_the_speccer_in_the_same_commit()

-- The reproduced incident: a bounce's gap lived only in the board
-- log, so the next session that pulled the same item re-discovered
-- it. `next`'s offer now carries the gap from the drop already on
-- record.
local function test_next_carries_the_last_bounce_gap()
  local s = init_state_repo("bouncenote")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_drop(s, leaf, "session-a",
      "the encoding question is unanswered", false) == 0)
  local all = check.must(store.list(s))
  local report = view.next_report_live(s, all, view.read_specs(s, all),
    "", {})
  assert(report:find("last bounce:", 1, true) ~= nil, report)
  assert(report:find("the encoding question is unanswered", 1, true) ~= nil,
    report)
end
test_next_carries_the_last_bounce_gap()
