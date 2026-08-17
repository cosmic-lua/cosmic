#!/usr/bin/env cosmic
-- The store is exercised against scratch git repositories this file
-- builds itself: a local-only store for the save/load/board mechanics,
-- and a bare "remote" with two clones for publish — including the case
-- the whole design exists for, where two sessions race a WIP limit and
-- the loser's push comes back rejected, rebases onto the winner, finds
-- the limit now binds, and drops its own commit instead of exceeding it.

local check = require("cosmic.check")
local cards = require("_work.card")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local model = require("_work.model")
local store = require("_work.store")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Run one git command in `cwd`, failing the test loudly if it does
--- not exit zero — fixture setup, not the code under test.
local function git(cwd: string, argv: {string})
  local full: {string} = {"git", "-c", "user.email=test@example.com",
    "-c", "user.name=test"}
  for _, a in ipairs(argv) do
    full[#full + 1] = a
  end
  local r = check.must(child.run(full, {cwd = cwd}))
  assert(r.ok, "git " .. table.concat(argv, " ") .. " failed: " .. r.stderr)
end

--- A fresh local-only state repo: git init, cards/, one seed commit.
local function init_state_repo(name: string): string
  local root = fs.join(tmpdir, "store-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(fs.join(root, "cards")))
  git(root, {"init", "-q"})
  assert(fs.write(fs.join(root, "cards", ".gitkeep"), ""))
  git(root, {"add", "-A"})
  git(root, {"commit", "-q", "-m", "init"})
  return root
end

--- A bare "remote" seeded with an empty cards/ tree, plus n clones.
local function init_shared(name: string, clones: integer): string, {string}
  local base = fs.join(tmpdir, "shared-" .. name)
  assert(fs.remove_all(base))
  assert(fs.make_dirs(base))
  local bare = fs.join(base, "remote.git")
  git(base, {"init", "-q", "--bare", bare})
  local seed = fs.join(base, "seed")
  git(base, {"clone", "-q", bare, seed})
  assert(fs.make_dirs(fs.join(seed, "cards")))
  assert(fs.write(fs.join(seed, "cards", ".gitkeep"), ""))
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

--- A minimal valid card.
local function make_card(issue: integer, phase: string): cards.Card
  return check.must(cards.decode({
        issue = issue, title = ("card %d"):format(issue), phase = phase,
      }))
end

local function test_save_load_and_history()
  local root = init_state_repo("roundtrip")
  local s = check.must(store.open(root, "whilp/cosmic"))
  assert(store.save(s, make_card(12, "plan"), "new #12 (plan)"))
  local c = check.must(store.load(s, 12))
  assert(c.phase == "plan", "phase: " .. c.phase)
  c.phase = "ready"
  assert(store.save(s, c, "move #12 plan -> ready"))
  local events = check.must(store.history(s, 12))
  assert(#events == 2, "want 2 events, got " .. #events)
  assert(events[1].subject == "move #12 plan -> ready", events[1].subject)
  assert(events[2].subject == "new #12 (plan)", events[2].subject)
  local missing, merr = store.load(s, 99)
  assert(missing == nil and merr:find("no card", 1, true), "missing card")
end
test_save_load_and_history()

local function test_board_groups_and_excludes_done()
  local root = init_state_repo("board")
  local s = check.must(store.open(root, "whilp/cosmic"))
  assert(store.save(s, make_card(1, "ready"), "new #1"))
  assert(store.save(s, make_card(2, "ready"), "new #2"))
  assert(store.save(s, make_card(3, "do"), "new #3"))
  local finished = make_card(4, "plan")
  finished.phase = cards.DONE
  finished.resolution = "completed"
  assert(store.save(s, finished, "done #4"))
  local b = check.must(store.board(s))
  assert(#(b["ready"] or {}) == 2, "ready count")
  assert(#(b["do"] or {}) == 1, "do count")
  assert(b["done"] == nil, "done cards are off the board")
  assert(store.is_open_fn(s)(1), "#1 is open")
  assert(not store.is_open_fn(s)(4), "#4 is done")
  assert(not store.is_open_fn(s)(99), "an uncarded issue does not block")
end
test_board_groups_and_excludes_done()

local function test_publish_fast_forward()
  local bare, clones = init_shared("ff", 2)
  assert(bare)
  local a = check.must(store.open(clones[1], "whilp/cosmic"))
  assert(store.save(a, make_card(21, "plan"), "new #21 (plan)"))
  assert(store.publish(a))
  local b = check.must(store.open(clones[2], "whilp/cosmic"))
  assert(store.sync(b))
  local c = check.must(store.load(b, 21))
  assert(c.phase == "plan", "the published card reaches the second clone")
end
test_publish_fast_forward()

-- Two sessions race the do limit (5): both see 4/5 and move a ready
-- card in. The first push wins; the loser's publish rebases onto the
-- merged state, finds do at 6/5, drops its own commit, and refuses —
-- the compare-and-swap the label board's lagged index cannot give.
local function test_publish_cas_refuses_over_limit()
  local _, clones = init_shared("cas", 2)
  local a = check.must(store.open(clones[1], "whilp/cosmic"))
  for i = 1, 4 do
    assert(store.save(a, make_card(i, "do"), ("new #%d (do)"):format(i)))
  end
  assert(store.save(a, make_card(10, "ready"), "new #10 (ready)"))
  assert(store.save(a, make_card(11, "ready"), "new #11 (ready)"))
  assert(store.publish(a))
  local b = check.must(store.open(clones[2], "whilp/cosmic"))
  assert(store.sync(b))

  local ca = check.must(store.load(a, 10))
  ca.phase = "do"
  assert(store.save(a, ca, "move #10 ready -> do"))
  assert(store.publish(a))

  local cb = check.must(store.load(b, 11))
  cb.phase = "do"
  assert(store.save(b, cb, "move #11 ready -> do"))
  local ok, err = store.publish(b, function(): string
      local merged = check.must(store.board(b))
      if model.limited_count(merged, "do") > model.LIMITS["do"] then
        return "do is over its limit"
      end
      return nil
    end)
  assert(not ok, "the losing move must be refused")
  assert(err:find("refused after concurrent update", 1, true), "got: " .. err)
  local back = check.must(store.load(b, 11))
  assert(back.phase == "ready", "the refused card is back in ready")
  local winner = check.must(store.load(b, 10))
  assert(winner.phase == "do", "the winning move is visible after the rebase")
  local merged = check.must(store.board(b))
  assert(model.limited_count(merged, "do") == 5, "do holds exactly its limit")
end
test_publish_cas_refuses_over_limit()
