#!/usr/bin/env cosmic
-- The store is exercised against scratch git repositories this file
-- builds itself: a local-only store for the save/load/spec mechanics,
-- and a bare "remote" with two clones for publish — including the case
-- the whole design exists for, where two sessions race a WIP limit and
-- the loser's push comes back rejected, rebases onto the winner, finds
-- the limit now binds, and drops its own commit instead of exceeding it.

local check = require("cosmic.check")
local child = require("cosmic.child")
local flow = require("_work.flow")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
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
--- checks — graph rules are flow's, exercised in flow_test).
local function make_item(phase: string): item.Item
  return check.must(item.decode({
        id = fresh_id(), title = "an item", parent = PARENT, phase = phase,
      }))
end

local function test_save_load_spec_and_history()
  local root = init_state_repo("roundtrip")
  local s = check.must(store.open(root))
  local it = make_item("plan")
  local short = it.id:sub(1, 8)
  assert(store.save(s, it, "new " .. short, "## Goal\nG1\n"))
  local loaded = check.must(store.load(s, it.id))
  assert(loaded.phase == "plan", "phase: " .. loaded.phase)
  assert(store.read_spec(s, it.id) == "## Goal\nG1\n", "spec sidecar")
  loaded.phase = "ready"
  assert(store.save(s, loaded, "move " .. short .. " plan -> ready"))
  assert(store.read_spec(s, it.id) == "## Goal\nG1\n",
    "a nil spec leaves the sidecar alone")
  local events = check.must(store.history(s, it.id))
  assert(#events == 2, "want 2 events, got " .. #events)
  assert(events[1].subject:find("plan %-> ready"), events[1].subject)
  local missing, merr = store.load(s, fresh_id())
  assert(missing == nil and merr:find("no item", 1, true), "missing item")
end
test_save_load_spec_and_history()

local function test_resolve_prefixes()
  local root = init_state_repo("resolve")
  local s = check.must(store.open(root))
  local a = make_item("plan")
  local b = make_item("plan")
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
  local parent = make_item("plan")
  assert(store.save(s, parent, "new parent"))
  local before = commit_count(root)
  local kid = make_item("plan")
  parent.phase = ""
  assert(store.save(s, kid, "new kid", nil, {parent}))
  assert(commit_count(root) == before + 1,
    ("one mutation, one commit: %d -> %d"):format(before, commit_count(root)))
  assert(check.must(store.load(s, parent.id)).phase == "",
    "the de-phased parent is in that commit")
  assert(check.must(store.load(s, kid.id)).phase == "plan", "so is the child")
end
test_save_writes_every_touched_item_as_one_commit()

-- A mutation that changes nothing must say so, not surface git's
-- exit code with the explanation on a stream nobody read.
local function test_save_refuses_a_no_op()
  local root = init_state_repo("noop")
  local s = check.must(store.open(root))
  local it = make_item("plan")
  assert(store.save(s, it, "new item"))
  local ok, err = store.save(s, it, "move it nowhere")
  assert(not ok, "an unchanged item is not a commit")
  assert(err:find("nothing to record", 1, true), "got: " .. err)
end
test_save_refuses_a_no_op()

local function test_publish_fast_forward()
  local bare, clones = init_shared("ff", 2)
  assert(bare)
  local a = check.must(store.open(clones[1]))
  local it = make_item("plan")
  assert(store.save(a, it, "new item"))
  assert(store.publish(a))
  local b = check.must(store.open(clones[2]))
  assert(store.sync(b))
  local got = check.must(store.load(b, it.id))
  assert(got.phase == "plan", "the published item reaches the second clone")
end
test_publish_fast_forward()

-- Two sessions race the do limit (5): both see 4/5 and move a ready
-- item in. The first push wins; the loser's publish rebases onto the
-- merged state, finds do at 6/5, drops its own commit, and refuses —
-- the compare-and-swap the label board's lagged index cannot give.
local function test_publish_cas_refuses_over_limit()
  local _, clones = init_shared("cas", 2)
  local a = check.must(store.open(clones[1]))
  for i = 1, 4 do
    assert(store.save(a, make_item("do"), ("busy %d"):format(i)))
  end
  local mine = make_item("ready")
  local yours = make_item("ready")
  assert(store.save(a, mine, "new mine"))
  assert(store.save(a, yours, "new yours"))
  assert(store.publish(a))
  local b = check.must(store.open(clones[2]))
  assert(store.sync(b))

  local ia = check.must(store.load(a, mine.id))
  ia.phase = "do"
  assert(store.save(a, ia, "move mine ready -> do"))
  assert(store.publish(a))

  local ib = check.must(store.load(b, yours.id))
  ib.phase = "do"
  assert(store.save(b, ib, "move yours ready -> do"))
  local ok, err = store.publish(b, function(): string
      local merged = check.must(store.list(b))
      local board = flow.board(merged)
      if #(board["do"] or {}) > flow.LIMITS["do"] then
        return "do is over its limit"
      end
      return nil
    end)
  assert(not ok, "the losing move must be refused")
  assert(err:find("refused after concurrent update", 1, true), "got: " .. err)
  local back = check.must(store.load(b, yours.id))
  assert(back.phase == "ready", "the refused item is back in ready")
  local winner = check.must(store.load(b, mine.id))
  assert(winner.phase == "do", "the winning move is visible after the rebase")
  local merged = flow.board(check.must(store.list(b)))
  assert(#(merged["do"] or {}) == 5, "do holds exactly its limit")
end
test_publish_cas_refuses_over_limit()

-- Two sessions editing the SAME item cannot rebase past each other.
-- git stops mid-rebase with conflict markers in the item file, which
-- is a state no later verb survives — a conflicted item is not
-- parseable literal data, so even `status` would die. The loser must
-- come back to a clean checkout holding the winner's state.
local function test_publish_unwinds_a_conflicting_rebase()
  local _, clones = init_shared("conflict", 2)
  local a = check.must(store.open(clones[1]))
  local contested = make_item("ready")
  assert(store.save(a, contested, "new contested"))
  assert(store.publish(a))
  local b = check.must(store.open(clones[2]))
  assert(store.sync(b))

  local ia = check.must(store.load(a, contested.id))
  ia.phase = "do"
  ia.claim = "session-a"
  assert(store.save(a, ia, "move contested ready -> do"))
  assert(store.publish(a))

  local ib = check.must(store.load(b, contested.id))
  ib.phase = "check"
  ib.pr = 7
  assert(store.save(b, ib, "move contested ready -> check"))
  local ok, err = store.publish(b)
  assert(not ok, "the losing edit of the same item must be refused")
  assert(err:find("concurrent edit", 1, true), "got: " .. err)
  assert(err:find(contested.id:sub(1, 8), 1, true),
    "the refusal names the contested item: " .. err)

  assert(not fs.is_present(fs.join(clones[2], ".git", "rebase-merge")),
    "no rebase may be left in progress")
  local after = check.must(store.load(b, contested.id))
  assert(after.phase == "do" and after.claim == "session-a",
    "the loser's checkout holds the winner's state: " .. after.phase)
  assert(store.list(b), "the board stays readable after the refusal")
end
test_publish_unwinds_a_conflicting_rebase()
