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
local fs = require("cosmic.fs")
local item = require("_work.item")
local store = require("_work.store")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Run one git command in `cwd`, failing the test loudly if it does
--- not exit zero — fixture setup, not the code under test. Objects
--- finalize by rename for the same reason store.tl's do: link-based
--- finalization fails with EXDEV on CI containers' overlay mounts.
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
local function init_shared(name: string, clones: integer): string, {string}
  local base = fs.join(tmpdir, "shared-" .. name)
  assert(fs.remove_all(base))
  assert(fs.make_dirs(base))
  local bare = fs.join(base, "remote.git")
  git(base, {"init", "-q", "--bare", bare})
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
    out[#out + 1] = dir
  end
  return bare, out
end

local counter = 0

--- A minimal valid slice (under an implicit hierarchy the store does
--- not check — trace rules are flow's, exercised in flow_test).
local function make_slice(id: string, phase: string): item.Item
  counter = counter + 1
  return check.must(item.decode({
        id = id, kind = "slice", title = "slice " .. id, parent = "e-one",
        phase = phase, opened = ("2026-08-17T00:00:%02dZ"):format(counter),
      }))
end

local function test_save_load_spec_and_history()
  local root = init_state_repo("roundtrip")
  local s = check.must(store.open(root))
  assert(store.save(s, make_slice("fly", "plan"), "## Goal\nG1\n",
      "new slice fly (plan)"))
  local it = check.must(store.load(s, "fly"))
  assert(it.phase == "plan", "phase: " .. it.phase)
  assert(store.read_spec(s, "fly") == "## Goal\nG1\n", "spec sidecar")
  it.phase = "ready"
  assert(store.save(s, it, nil, "move fly plan -> ready"))
  assert(store.read_spec(s, "fly") == "## Goal\nG1\n",
    "a nil spec leaves the sidecar alone")
  local events = check.must(store.history(s, "fly"))
  assert(#events == 2, "want 2 events, got " .. #events)
  assert(events[1].subject == "move fly plan -> ready", events[1].subject)
  assert(events[2].subject == "new slice fly (plan)", events[2].subject)
  local missing, merr = store.load(s, "nope")
  assert(missing == nil and merr:find("no item", 1, true), "missing item")
end
test_save_load_spec_and_history()

local function test_list_reads_every_item()
  local root = init_state_repo("list")
  local s = check.must(store.open(root))
  assert(store.save(s, make_slice("aa", "ready"), nil, "new aa"))
  assert(store.save(s, make_slice("bb", "do"), nil, "new bb"))
  local all = check.must(store.list(s))
  assert(#all == 2, "want 2 items, got " .. #all)
  local b = flow.board(all)
  assert(#(b["ready"] or {}) == 1 and #(b["do"] or {}) == 1, "board groups")
end
test_list_reads_every_item()

local function test_publish_fast_forward()
  local bare, clones = init_shared("ff", 2)
  assert(bare)
  local a = check.must(store.open(clones[1]))
  assert(store.save(a, make_slice("first", "plan"), nil, "new first (plan)"))
  assert(store.publish(a))
  local b = check.must(store.open(clones[2]))
  assert(store.sync(b))
  local it = check.must(store.load(b, "first"))
  assert(it.phase == "plan", "the published item reaches the second clone")
end
test_publish_fast_forward()

-- Two sessions race the do limit (5): both see 4/5 and move a ready
-- slice in. The first push wins; the loser's publish rebases onto the
-- merged state, finds do at 6/5, drops its own commit, and refuses —
-- the compare-and-swap the label board's lagged index cannot give.
local function test_publish_cas_refuses_over_limit()
  local _, clones = init_shared("cas", 2)
  local a = check.must(store.open(clones[1]))
  for i = 1, 4 do
    local id = ("busy-%d"):format(i)
    assert(store.save(a, make_slice(id, "do"), nil, "new " .. id))
  end
  assert(store.save(a, make_slice("mine", "ready"), nil, "new mine"))
  assert(store.save(a, make_slice("yours", "ready"), nil, "new yours"))
  assert(store.publish(a))
  local b = check.must(store.open(clones[2]))
  assert(store.sync(b))

  local ia = check.must(store.load(a, "mine"))
  ia.phase = "do"
  assert(store.save(a, ia, nil, "move mine ready -> do"))
  assert(store.publish(a))

  local ib = check.must(store.load(b, "yours"))
  ib.phase = "do"
  assert(store.save(b, ib, nil, "move yours ready -> do"))
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
  local back = check.must(store.load(b, "yours"))
  assert(back.phase == "ready", "the refused slice is back in ready")
  local winner = check.must(store.load(b, "mine"))
  assert(winner.phase == "do", "the winning move is visible after the rebase")
  local merged = flow.board(check.must(store.list(b)))
  assert(#(merged["do"] or {}) == 5, "do holds exactly its limit")
end
test_publish_cas_refuses_over_limit()
