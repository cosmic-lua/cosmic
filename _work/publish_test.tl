#!/usr/bin/env cosmic
-- A mutating verb is independent of the shared worktree's state at
-- paths it does not own. `sync`/`rebase_onto_remote`'s `git fetch` +
-- `git merge --ff-only` tolerates an unrelated dirty file and refuses
-- by name on an overlapping one; `publish`'s lost-race recovery drops
-- the mutation whole via `reset --mixed` plus a targeted checkout of
-- only its own paths, leaving a dirty file elsewhere byte-identical —
-- the regression test for the `reset --hard` hazard that mechanism
-- replaces. `git stash list` stays empty throughout: the machinery
-- must never reach for the stack, which is shared across every
-- worktree of this repo.

local check = require("cosmic.check")
local child = require("cosmic.child")
local fixture = require("_work.fixture")
local fs = require("cosmic.fs")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local publish = require("_work.publish")
local store = require("_work.store")

local init_shared = fixture.init_shared
local file_item = fixture.file_item

local counter = 0

--- A fresh deterministic id; later calls sort later.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

local PARENT = check.must(ksuid.encode(1690000000, ("\1"):rep(16)))

--- A minimal valid workable item, filed directly through the store so
--- a test can commit and publish as two separate steps — `fixture`'s
--- `file_item` does both at once through the `new` verb, which cannot
--- construct a race on its own.
--- @return item.Item
local function make_item(): item.Item
  return check.must(item.decode({
        id = fresh_id(), title = "an item", parent = PARENT,
      }))
end

--- `git stash list`, empty when the shared stack has never been
--- touched — the one escape this machinery must never reach for.
--- @param root string Checkout root
--- @return string Stash listing, "" when empty
local function stash_list(root: string): string
  local r = check.must(child.run({"git", "stash", "list"}, {cwd = root}))
  assert(r.ok, "git stash list failed: " .. r.stderr)
  return (r.stdout:gsub("%s+$", ""))
end

--- The paths a commit touched, newest first — how a test reads back
--- what a mutation actually staged.
--- @param root string Checkout root
--- @return {string} File paths
local function commit_paths(root: string): {string}
  local r = check.must(child.run(
      {"git", "show", "--name-only", "--format=", "HEAD"}, {cwd = root}))
  assert(r.ok, "git show failed: " .. r.stderr)
  local out: {string} = {}
  for line in r.stdout:gmatch("([^\n]+)") do
    out[#out + 1] = line
  end
  return out
end

--- Commit and push a `_work/**` file so a later unstaged edit to it is
--- a MODIFICATION of a path git already tracks — the shape the actual
--- hazard needs. A freshly created untracked file does not exercise
--- it: git already tolerates those, on both the old `pull --rebase`
--- and `reset --hard`, so a test dirtying one would pass whether or
--- not the fix under test does anything at all.
--- @param root string Checkout root
--- @param path string File path relative to root, e.g. "_work/x.tl"
--- @param content string Content
local function seed_tracked_file(root: string, path: string, content: string)
  assert(fs.make_dirs(fs.dirname(fs.join(root, path))))
  assert(fs.write(fs.join(root, path), content))
  fixture.git(root, {"add", "-A"})
  fixture.git(root, {"commit", "-q", "-m", "seed " .. path})
  fixture.git(root, {"push", "-q", "origin", "HEAD"})
end

-- A modified-but-unrelated `_work/**` file sitting dirty in the
-- checkout must not block a sync that has real work to pull in, and a
-- mutation's own commit must carry exactly the item's files — nothing
-- from the dirty path leaks in, and the dirty path is not disturbed by
-- either. Against the pre-fix whole-tree `git pull --rebase`, both the
-- sync and the mutation below refuse outright the moment the file is
-- dirty, regardless of what path the incoming commit touches.
local function test_a_dirty_unrelated_file_does_not_block_a_mutation()
  local a, b = init_shared("dirty-unrelated")
  seed_tracked_file(a.root, fs.join("_work", "x.tl"), "-- base\n")
  assert(publish.sync(b))
  file_item(a, "a's item, for b to pull in", "")

  local dirty_path = fs.join(b.root, "_work", "x.tl")
  assert(fs.write(dirty_path, "-- an in-progress machinery edit\n"))

  assert(publish.sync(b), "sync must tolerate the unrelated dirty file")
  local after_sync = fs.read(dirty_path)
  assert(after_sync == "-- an in-progress machinery edit\n",
    "the dirty file is byte-identical after a real sync")

  local id = file_item(b, "a workable slice filed over dirt", "")
  local paths = commit_paths(b.root)
  assert(#paths == 1 and paths[1] == fs.join("items", id .. ".tl"),
    "the commit is exactly the item's file: " .. table.concat(paths, ", "))
  local after_mutation = fs.read(dirty_path)
  assert(after_mutation == "-- an in-progress machinery edit\n",
    "the dirty file is byte-identical after the mutation")
  assert(stash_list(b.root) == "", "the shared stash stack is untouched")
end
test_a_dirty_unrelated_file_does_not_block_a_mutation()

-- The regression test for the `reset --hard` hazard: a lost push race
-- with an unrelated `_work/**` file dirty must still drop the losing
-- mutation and refuse LOST_RACE, WITHOUT destroying that file. Against
-- the pre-fix `reset --hard HEAD~1`, this fails — the hard reset wipes
-- every uncommitted MODIFICATION in the checkout, tracked paths
-- included, the moment the drop runs, whether or not the mutation
-- itself ever touched that path. `reset --mixed` plus a checkout of
-- only the dropped commit's own paths must not.
local function test_a_lost_race_preserves_unrelated_dirt()
  local a, b = init_shared("race-dirt")
  seed_tracked_file(a.root, fs.join("_work", "y.tl"), "-- base\n")
  -- A common base both checkouts hold before either mutates, so b's
  -- own commit below is built against state the winner's push makes
  -- stale rather than one that already contains it.
  local base = make_item()
  assert(store.save(a, base, "seed a common base"))
  assert(publish.publish(a))
  assert(publish.sync(b))

  local dirty_path = fs.join(b.root, "_work", "y.tl")
  assert(fs.write(dirty_path, "-- precious uncommitted work\n"))

  -- a wins the race, publishing from the same base b still holds.
  local winner = make_item()
  assert(store.save(a, winner, "a wins the race"))
  assert(publish.publish(a))

  -- b's commit, built and pushed against the now-stale base, loses.
  local loser = make_item()
  assert(store.save(b, loser, "b loses the race"))
  local ok, err = publish.publish(b)
  assert(not ok and err == store.LOST_RACE,
    "the losing mutation must refuse LOST_RACE: " .. tostring(err))
  assert(store.load(b, loser.id) == nil, "the dropped mutation is gone whole")
  assert(check.must(store.load(b, winner.id)).id == winner.id,
    "the checkout holds the winner's state")
  local after = fs.read(dirty_path)
  assert(after == "-- precious uncommitted work\n",
    "the dirty file is byte-identical after the lost race")
  assert(stash_list(b.root) == "", "the shared stash stack is untouched")
end
test_a_lost_race_preserves_unrelated_dirt()

-- An incoming `_work/**` commit that overlaps a local uncommitted edit
-- to the SAME path is the one case a fast-forward cannot silently
-- resolve: it must refuse, naming the file, with no conflict markers
-- and no stash entry — never a resolved merge.
local function test_an_overlapping_dirty_file_refuses_by_name()
  local a, b = init_shared("dirty-overlap")
  local shared_path = fs.join("_work", "z.tl")
  assert(fs.make_dirs(fs.join(a.root, "_work")))
  assert(fs.write(fs.join(a.root, "_work", "z.tl"), "-- base\n"))
  fixture.git(a.root, {"add", "-A"})
  fixture.git(a.root, {"commit", "-q", "-m", "seed _work/z.tl"})
  fixture.git(a.root, {"push", "-q", "origin", "HEAD"})
  assert(publish.sync(b))

  assert(fs.write(fs.join(a.root, "_work", "z.tl"), "-- a's change\n"))
  fixture.git(a.root, {"add", "-A"})
  fixture.git(a.root, {"commit", "-q", "-m", "a changes _work/z.tl"})
  fixture.git(a.root, {"push", "-q", "origin", "HEAD"})

  local dirty_path = fs.join(b.root, "_work", "z.tl")
  assert(fs.write(dirty_path, "-- b's uncommitted change\n"))
  local ok, err = publish.sync(b)
  assert(not ok, "an overlapping sync must be refused")
  assert(err:find(shared_path, 1, true), "the refusal names the file: " .. err)
  assert(err:find("--dir", 1, true),
    "the refusal points at the --dir remedy: " .. err)
  assert(not fs.is_present(fs.join(b.root, ".git", "rebase-merge")),
    "no conflict markers are ever staged")
  local after = fs.read(dirty_path)
  assert(after == "-- b's uncommitted change\n",
    "the overlapping edit is preserved, not merged")
  assert(stash_list(b.root) == "", "the shared stash stack is untouched")
end
test_an_overlapping_dirty_file_refuses_by_name()

-- An unreadable remote — the fetch itself fails, not the merge — is a
-- clean refusal too, never a crash, and it must not touch the checkout
-- at all: unlike a fast-forward refusal, there is nothing to name.
local function test_an_unreachable_remote_refuses_cleanly()
  local a = init_shared("unreachable")
  fixture.git(a.root, {"remote", "set-url", "origin",
      fs.join(fixture.tmpdir, "no-such-remote.git")})
  local ok, err = publish.sync(a)
  assert(not ok, "a sync against an unreadable remote must refuse")
  assert(err ~= store.LOST_RACE, "an unreadable remote is not a race: " .. err)
end
test_an_unreachable_remote_refuses_cleanly()

print("all publish tests passed")
