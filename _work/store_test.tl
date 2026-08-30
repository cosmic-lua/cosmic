#!/usr/bin/env cosmic
-- The store is exercised against scratch git repositories this file
-- builds itself: a local-only store for the save/load/spec mechanics,
-- and a bare "remote" with two clones for publish — including the case
-- the whole design exists for, where two sessions race and the loser's
-- push comes back rejected: the mutation is dropped whole, the
-- checkout re-syncs onto the winner's state, and the refusal is
-- LOST_RACE, so the re-run verb decides against the merged board.

local check = require("cosmic.check")
local child = require("cosmic.child")
local flow = require("_work.flow")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local literal = require("cosmic.literal")
local publish = require("_work.publish")
local store = require("_work.store")

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

--- Run one git command in `cwd`, failing the test loudly if it does
--- not exit zero — fixture setup, not the code under test.
local function git(cwd: string, argv: {string})
  local full: {string} = {"git", "-c", "user.email=test@example.com",
    "-c", "user.name=test", "-c", "core.createObject=rename"}
  for _, a in ipairs(argv) do
    full[#full + 1] = a
  end
  local r = check.must(child.run(full, {cwd = cwd}))
  assert(r.ok, "git " .. table.concat(argv, " ") .. " failed: " .. r.stderr)
end

--- A fresh local-only state repo: git init, items/, one seed commit.
local function init_state_repo(name: string): string
  local root = fs.join(tmpdir, "store-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(fs.join(root, "items")))
  git(root, {"init", "-q"})
  assert(fs.write(fs.join(root, "items", ".gitkeep"), ""))
  git(root, {"add", "-A"})
  git(root, {"commit", "-q", "-m", "init"})
  return root
end

--- A bare "remote" seeded with an empty items/ tree, plus n clones.
--- The bare side finalizes objects by rename in ITS OWN config: a
--- file:// push spawns receive-pack with the pusher's `-c` env
--- scrubbed (git's local transport clears GIT_CONFIG_PARAMETERS), and
--- link-based finalization fails with EXDEV on the overlay mounts CI
--- containers run tests on.
local function init_shared(name: string, clones: integer): string, {string}
  local base = fs.join(tmpdir, "shared-" .. name)
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
  local out: {string} = {}
  for i = 1, clones do
    local dir = fs.join(base, ("clone%d"):format(i))
    git(base, {"clone", "-q", bare, dir})
    git(dir, {"config", "core.createObject", "rename"})
    out[#out + 1] = dir
  end
  return bare, out
end

--- How many commits a checkout carries — fixture arithmetic for the
--- one-commit-per-mutation property.
local function commit_count(cwd: string): integer
  local r = check.must(child.run({"git", "rev-list", "--count", "HEAD"},
      {cwd = cwd}))
  assert(r.ok, "git rev-list failed: " .. r.stderr)
  return math.tointeger(tonumber((r.stdout:gsub("%s+$", "")))) or -1
end

local counter = 0

--- A fresh deterministic id; later calls sort later.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

local PARENT = check.must(ksuid.encode(1690000000, ("\1"):rep(16)))

--- A minimal valid workable item (under a parent the store never
--- checks — graph rules are flow's, exercised in flow_test). The
--- claim doubles as the mutable payload the round-trip tests edit.
local function make_item(claim?: string): item.Item
  return check.must(item.decode({
        id = fresh_id(), title = "an item", parent = PARENT,
        claim = claim or "",
      }))
end

--- Write a content-invalid item file directly, bypassing `stage`'s
--- refusal — a pre-refusal writer's shape, or a hand edit.
--- @param s store.Store The store
--- @param bad item.Item An item whose `item.problems` is non-empty
local function write_unchecked(s: store.Store, bad: item.Item)
  assert(literal.format_file(store.item_path(s, bad.id), item.encode(bad)))
end

-- init_repo prepares a fresh directory whole: a git worktree (created
-- when none is there) plus an items/ directory a `.gitkeep` makes
-- trackable — exactly what `open` requires.
local function test_init_repo_creates_a_fresh_git_and_items_dir()
  local root = fs.join(tmpdir, "init-fresh")
  assert(fs.remove_all(root))
  assert(store.init_repo(root))
  assert(fs.is_present(fs.join(root, ".git")), "a git repo now exists")
  assert(fs.is_dir(fs.join(root, "items")), "and items/")
  assert(fs.is_file(fs.join(root, "items", ".gitkeep")))
  assert(check.must(store.open(root)).root == root,
    "open accepts exactly what init_repo left")
end
test_init_repo_creates_a_fresh_git_and_items_dir()

-- A directory that is already a git repo (no `.git` to create) still
-- gets its items/ directory, and a second call over the same tree is
-- a no-op yes rather than a refusal.
local function test_init_repo_is_idempotent_over_an_existing_git()
  local root = fs.join(tmpdir, "init-existing")
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  git(root, {"init", "-q"})
  assert(store.init_repo(root))
  assert(fs.is_dir(fs.join(root, "items")))
  assert(store.init_repo(root), "a second call over the same tree is a yes")
end
test_init_repo_is_idempotent_over_an_existing_git()

local function test_save_load_spec_and_history()
  local root = init_state_repo("roundtrip")
  local s = check.must(store.open(root))
  local it = make_item("session-a")
  local short = it.id:sub(1, 8)
  assert(store.save(s, it, "new " .. short, "## Change\nG1\n"))
  local loaded = check.must(store.load(s, it.id))
  assert(loaded.claim == "session-a", "claim: " .. loaded.claim)
  assert(store.read_spec(s, it.id) == "## Change\nG1\n", "spec sidecar")
  loaded.claim = "session-b"
  assert(store.save(s, loaded, "take " .. short .. " by session-b"))
  assert(store.read_spec(s, it.id) == "## Change\nG1\n",
    "a nil spec leaves the sidecar alone")
  local events = check.must(publish.history(s, it.id))
  assert(#events == 2, "want 2 events, got " .. #events)
  assert(events[1].subject:find("by session%-b"), events[1].subject)
  local missing, merr = store.load(s, fresh_id())
  assert(missing == nil and merr:find("no item", 1, true), "missing item")
end
test_save_load_spec_and_history()

-- An item is two files, and a `spec` mutation touches only the second
-- one. A trail narrowed to the record would leave every refinement out
-- of it, which is how a spec that replaced another spec went unseen.
local function test_history_covers_the_spec_sidecar()
  local root = init_state_repo("sidecar-history")
  local s = check.must(store.open(root))
  local it = make_item()
  local short = it.id:sub(1, 8)
  assert(store.save(s, it, "new " .. short, "## Change\nG1\n"))
  assert(store.save(s, it, "spec " .. short, "## Change\nG8\n"))
  local events = check.must(publish.history(s, it.id))
  assert(#events == 2, "want 2 events, got " .. #events)
  assert(events[1].subject == "spec " .. short,
    "the sidecar-only commit is in the trail: " .. events[1].subject)
end
test_history_covers_the_spec_sidecar()

local function test_resolve_prefixes()
  local root = init_state_repo("resolve")
  local s = check.must(store.open(root))
  local a = make_item()
  local b = make_item()
  assert(store.save(s, a, "new a"))
  assert(store.save(s, b, "new b"))
  assert(check.must(store.resolve(s, a.id)) == a.id, "full ids resolve")
  assert(check.must(store.resolve(s, a.id:sub(1, 26))) == a.id,
    "a unique prefix resolves")
  -- The deterministic ids share all but their trailing bytes, so the
  -- short common prefix is ambiguous by construction.
  local amb, aerr = store.resolve(s, a.id:sub(1, 4))
  assert(amb == nil and aerr:find("ambiguous", 1, true), "ambiguity is named")
  local none, nerr = store.resolve(s, "zzzz")
  assert(none == nil and nerr:find("no item", 1, true), "a miss is named")
end
test_resolve_prefixes()

-- Everything one mutation touches lands in ONE commit, because that
-- is what makes publish's "drop the refused mutation" exact.
local function test_save_writes_every_touched_item_as_one_commit()
  local root = init_state_repo("atomic")
  local s = check.must(store.open(root))
  local parent = make_item("session-a")
  assert(store.save(s, parent, "new parent"))
  local before = commit_count(root)
  local kid = make_item()
  parent.claim = ""
  assert(store.save(s, kid, "new kid", nil, {parent}))
  assert(commit_count(root) == before + 1,
    ("one mutation, one commit: %d -> %d"):format(before, commit_count(root)))
  assert(check.must(store.load(s, parent.id)).claim == "",
    "the unlocked parent is in that commit")
  assert(check.must(store.load(s, kid.id)).id == kid.id, "so is the child")
end
test_save_writes_every_touched_item_as_one_commit()

-- A mutation that changes nothing must say so, not surface git's
-- exit code with the explanation on a stream nobody read.
local function test_save_refuses_a_no_op()
  local root = init_state_repo("noop")
  local s = check.must(store.open(root))
  local it = make_item()
  assert(store.save(s, it, "new item"))
  local ok, err = store.save(s, it, "take it nowhere")
  assert(not ok, "an unchanged item is not a commit")
  assert(err:find("nothing to record", 1, true), "got: " .. err)
end
test_save_refuses_a_no_op()

-- The bricking incident: a multiline title must not abort `list` — the
-- rest still reads, the bad one comes back flagged, not dropped, and
-- write-refusal is unchanged (`stage` still refuses the same shape).
local function test_list_tolerates_a_bad_title_but_stage_still_refuses()
  local root = init_state_repo("list-tolerant")
  local s = check.must(store.open(root))
  local good = make_item()
  assert(store.save(s, good, "new good"))
  local bad = check.must(item.decode({id = fresh_id(), title = "one line"}))
  bad.title = "broken\ntitle"
  local ok, serr = store.stage(s, bad)
  assert(not ok and serr:find("title must be one line", 1, true) ~= nil,
    "stage refuses the same shape: " .. tostring(serr))
  write_unchecked(s, bad)
  local all = check.must(store.list(s))
  assert(#all == 2, "the bad record is included, not dropped: got " .. #all)
  for _, it in ipairs(all) do
    assert(item.is_flagged(it) == (it.id == bad.id), "flagged iff bad")
  end
  local summary = store.flagged_summary(all)
  assert(summary:find(bad.id:sub(1, 8), 1, true) and
    summary:find("title must be one line", 1, true), "summary: " .. summary)
end
test_list_tolerates_a_bad_title_but_stage_still_refuses()

-- Repairability falls out: `set --title` loads through this same
-- tolerant decode, so overwriting the bad title and saving clears it.
local function test_a_bad_title_is_repairable_through_the_tolerant_decode()
  local root = init_state_repo("repair")
  local s = check.must(store.open(root))
  local seed = check.must(item.decode({id = fresh_id(), title = "one line"}))
  seed.title = "broken\ntitle"
  write_unchecked(s, seed)
  local loaded = check.must(store.load(s, seed.id))
  assert(item.is_flagged(loaded), "the bad record still loads, flagged")
  loaded.title = "a repaired one-line title"
  assert(store.save(s, loaded, "set " .. seed.id:sub(1, 8) .. " title"),
    "the repair commits: problems(it) is now empty")
  local fixed = check.must(store.load(s, seed.id))
  assert(not item.is_flagged(fixed) and fixed.title == loaded.title, "clean")
  assert(store.flagged_summary(check.must(store.list(s))) == "",
    "listing recovers: nothing left flagged")
end
test_a_bad_title_is_repairable_through_the_tolerant_decode()

local function test_publish_fast_forward()
  local bare, clones = init_shared("ff", 2)
  assert(bare)
  local a = check.must(store.open(clones[1]))
  local it = make_item("session-a")
  assert(store.save(a, it, "new item"))
  assert(publish.publish(a))
  local b = check.must(store.open(clones[2]))
  assert(publish.sync(b))
  local got = check.must(store.load(b, it.id))
  assert(got.claim == "session-a",
    "the published item reaches the second clone")
end
test_publish_fast_forward()

-- Two sessions race the last doing slot: both see room and take. The
-- first push wins; the loser's publish drops its commit whole,
-- re-syncs, and refuses with LOST_RACE — the verb re-runs against the
-- merged board, whose doing bound refuses the take, which is the
-- compare-and-swap a lagged index cannot give.
local function test_publish_drops_a_lost_race()
  local _, clones = init_shared("cas", 2)
  local a = check.must(store.open(clones[1]))
  for i = 1, flow.DOING_LIMIT - 1 do
    assert(store.save(a, make_item(("busy-%d"):format(i)),
        ("busy %d"):format(i)))
  end
  local mine = make_item()
  local yours = make_item()
  assert(store.save(a, mine, "new mine"))
  assert(store.save(a, yours, "new yours"))
  assert(publish.publish(a))
  local b = check.must(store.open(clones[2]))
  assert(publish.sync(b))

  local ia = check.must(store.load(a, mine.id))
  ia.claim = "session-a"
  assert(store.save(a, ia, "take mine by session-a"))
  assert(publish.publish(a))

  local ib = check.must(store.load(b, yours.id))
  ib.claim = "session-b"
  assert(store.save(b, ib, "take yours by session-b"))
  local ok, err = publish.publish(b)
  assert(not ok, "the losing take must be refused")
  assert(err == store.LOST_RACE, "got: " .. err)
  local back = check.must(store.load(b, yours.id))
  assert(back.claim == "", "the dropped mutation is undone whole")
  local winner = check.must(store.load(b, mine.id))
  assert(winner.claim == "session-a",
    "the winning take is visible after the sync")
  assert(flow.doing_refusal(check.must(store.list(b))) ~= nil,
    "doing holds exactly its bound — the re-run verb's own gate now "
    .. "refuses this take")
end
test_publish_drops_a_lost_race()

-- Two sessions edit the SAME item. The loser's commit is dropped
-- before any rebase could conflict, so there is no mid-rebase state
-- for a later verb to die on: the refusal is the same LOST_RACE every
-- lost race gets, and the re-run verb — loading the winner's state —
-- is what discovers the semantic collision (a claim guard, a phase
-- gate) and names it.
local function test_publish_drops_a_lost_edit_of_the_same_item()
  local _, clones = init_shared("conflict", 2)
  local a = check.must(store.open(clones[1]))
  local contested = make_item()
  assert(store.save(a, contested, "new contested"))
  assert(publish.publish(a))
  local b = check.must(store.open(clones[2]))
  assert(publish.sync(b))

  local ia = check.must(store.load(a, contested.id))
  ia.claim = "session-a"
  assert(store.save(a, ia, "take contested by session-a"))
  assert(publish.publish(a))

  local ib = check.must(store.load(b, contested.id))
  ib.claim = "session-b"
  ib.pr = 7
  assert(store.save(b, ib, "take contested by session-b"))
  local ok, err = publish.publish(b)
  assert(not ok, "the losing edit of the same item must be refused")
  assert(err == store.LOST_RACE, "got: " .. err)

  assert(not fs.is_present(fs.join(clones[2], ".git", "rebase-merge")),
    "no rebase may be left in progress")
  local after = check.must(store.load(b, contested.id))
  assert(after.claim == "session-a" and after.pr == 0,
    "the loser's checkout holds the winner's state: " .. after.claim)
  assert(store.list(b), "the board stays readable after the refusal")
end
test_publish_drops_a_lost_edit_of_the_same_item()

-- A checkout carrying an UNPUBLISHED local commit (the hand-edit
-- workaround the skill allows when a verb is missing) that syncs
-- against a remote which advanced too has DIVERGED history — neither
-- is the other's ancestor — so `git merge --ff-only` refuses outright
-- rather than attempting any content merge: no conflict markers ever
-- land in the item file, and board history being linear here (commits
-- reach this branch only through this same fast-forward path) means
-- that refusal is the compare-and-swap's own shape surfacing, not a
-- new failure mode.
local function test_sync_refuses_a_diverged_local_commit()
  local _, clones = init_shared("sync-conflict", 2)
  local a = check.must(store.open(clones[1]))
  local contested = make_item()
  assert(store.save(a, contested, "new contested"))
  assert(publish.publish(a))
  local b = check.must(store.open(clones[2]))
  assert(publish.sync(b))

  local ia = check.must(store.load(a, contested.id))
  ia.claim = "session-a"
  assert(store.save(a, ia, "take contested by session-a"))
  assert(publish.publish(a))

  local ib = check.must(store.load(b, contested.id))
  ib.claim = "session-b"
  ib.pr = 7
  assert(store.save(b, ib, "hand-edit contested for session-b"))
  local ok, err = publish.sync(b)
  assert(not ok, "a diverged sync must be refused")
  assert(err ~= store.LOST_RACE, "a sync refusal is not a race refusal: " .. err)
  assert(err:find("local commits", 1, true),
    "the refusal names the cause: " .. err)
  assert(err:find("git log", 1, true),
    "the refusal names the remedy: " .. err)
  assert(err:find("--dir", 1, true),
    "the refusal points a _work/** slice at its own clone: " .. err)
  assert(not fs.is_present(fs.join(clones[2], ".git", "rebase-merge")),
    "no rebase is ever attempted, so none is left in progress")
  assert(check.must(store.load(b, contested.id)).claim == "session-b",
    "the refusal leaves the checkout exactly as it was")
  assert(store.list(b), "the board stays readable after the refusal")
end
test_sync_refuses_a_diverged_local_commit()

-- The one publish path that can still conflict: a checkout carrying an
-- unpublished hand-edit commit BENEATH the verb's commit. Dropping the
-- verb's own commit is `reset --mixed HEAD~1` plus restoring only the
-- paths that commit touched, so the hand-edit commit beneath it is
-- left standing as the new HEAD; the re-sync that follows then finds
-- it diverged from the remote (both changed the contested item) and
-- refuses — and the refusal must say the mutation was already
-- dropped, or a user reads the conflict report and does not know
-- their verb's change is gone.
local function test_publish_names_the_drop_when_the_resync_conflicts()
  local _, clones = init_shared("drop-conflict", 2)
  local a = check.must(store.open(clones[1]))
  local contested = make_item()
  assert(store.save(a, contested, "new contested"))
  assert(publish.publish(a))
  local b = check.must(store.open(clones[2]))
  assert(publish.sync(b))

  local ia = check.must(store.load(a, contested.id))
  ia.claim = "session-a"
  assert(store.save(a, ia, "take contested by session-a"))
  assert(publish.publish(a))

  -- b's hand-edit of the contested item, unpublished, then a verb's
  -- mutation of another item on top of it.
  local ib = check.must(store.load(b, contested.id))
  ib.claim = "session-b"
  ib.pr = 9
  assert(store.save(b, ib, "hand-edit contested for session-b"))
  local mine = make_item()
  assert(store.save(b, mine, "new mine"))
  local ok, err = publish.publish(b)
  assert(not ok, "the push is rejected and the re-sync then diverges")
  assert(err:find("the mutation was dropped whole", 1, true), "got: " .. err)
  local gone = store.load(b, mine.id)
  assert(gone == nil, "the verb's mutation is gone whole")
  local kept = check.must(store.load(b, contested.id))
  assert(kept.claim == "session-b" and kept.pr == 9,
    "the unpublished hand-edit beneath it survives the unwind")
end
test_publish_names_the_drop_when_the_resync_conflicts()

-- A rejection with the remote unmoved is the remote's policy — a
-- pre-receive hook, a read-only token — not a race. The destructive
-- branch must not run: the commit stays local, the refusal does not
-- claim a race, and the remote's own words reach the caller instead
-- of being swallowed.
local function test_publish_keeps_the_mutation_on_a_policy_rejection()
  local bare, clones = init_shared("policy", 1)
  local a = check.must(store.open(clones[1]))
  local hook = fs.join(bare, "hooks", "pre-receive")
  assert(fs.write(hook,
      "#!/bin/sh\necho 'policy: board is read-only' >&2\nexit 1\n"))
  assert(fs.set_mode(hook, fs.octal("755")))

  local it = make_item("session-a")
  assert(store.save(a, it, "new under policy"))
  local before = commit_count(clones[1])
  local ok, err = publish.publish(a)
  assert(not ok, "the rejected push must refuse")
  assert(err ~= store.LOST_RACE and not err:find("lost the push race", 1, true),
    "no race is claimed when the remote never moved: " .. err)
  assert(err:find("policy: board is read-only", 1, true),
    "the remote's own words reach the caller: " .. err)
  assert(err:find("still local", 1, true), "and the refusal says the "
    .. "commit survives: " .. err)
  assert(commit_count(clones[1]) == before,
    "the mutation was not destroyed")
  assert(check.must(store.load(a, it.id)).claim == "session-a",
    "and still reads back")
end
test_publish_keeps_the_mutation_on_a_policy_rejection()
