#!/usr/bin/env cosmic
--- reads: bin/gitboard
-- bin/gitboard's default GITBOARD_DIR: a sibling ../work clone of
-- cosmic-lua/work wins over o/board, an inherited GITBOARD_DIR wins
-- over both, and the bootstrap stub is pre-placed so nothing downloads.

local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- A fake ROOT with bin/gitboard, its pin, and an already-valid stub
--- bootstrap (so ensure_bootstrap downloads nothing) echoing $GITBOARD_DIR.
local function make_root(name: string): string
  local root = fs.join(tmpdir, "gbroot-" .. name, "root")
  assert(fs.remove_all(fs.dirname(root)))
  assert(fs.make_dirs(fs.join(root, "bin")))
  assert(fs.make_dirs(fs.join(root, "o", "bootstrap")))
  assert(fs.copy("bin/gitboard", fs.join(root, "bin", "gitboard")))
  assert(fs.write(fs.join(root, "bin", "gitboard.pin"),
      "url = https://example.invalid/gitboard\nsha256 = test-sha\n"))
  local boot = fs.join(root, "o", "bootstrap", "gitboard")
  assert(fs.write(boot, "#!/bin/sh\necho \"$GITBOARD_DIR\"\n", {mode = fs.octal("755")}))
  assert(fs.write(boot .. ".pin", "test-sha\n"))
  return root
end

local function sibling(root: string, origin: string): string -- ${ROOT}/../work, with origin set
  local sib = fs.join(fs.dirname(root), "work")
  assert(fs.make_dirs(sib))
  local r = check.must(child.run({"sh", "-c",
        "git init -q && git remote add origin " .. origin}, {cwd = sib}))
  assert(r.ok, "git setup failed: " .. r.stderr)
  return sib
end

local function run(root: string, envlist?: {string}): string -- runs the fixture, trimmed stub echo
  local r = check.must(child.run({fs.join(root, "bin", "gitboard"), "sync"},
      {cwd = root, env = envlist}))
  assert(r.ok, "gitboard failed: " .. r.stderr)
  return ((r.stdout or ""):gsub("%s+$", ""))
end

local function test_prefers_a_sibling_work_clone()
  local root = make_root("sibling")
  local sib = sibling(root, "https://github.com/cosmic-lua/work")
  assert(run(root) == sib)
end
local function test_prefers_an_ssh_sibling_work_clone()
  local root = make_root("ssh-sibling")
  local sib = sibling(root, "git@github.com:cosmic-lua/work.git")
  assert(run(root) == sib)
end
local function test_refuses_a_sibling_whose_org_merely_ends_in_cosmic_lua()
  local root = make_root("evil-org")
  sibling(root, "https://github.com/evilcosmic-lua/work")
  assert(run(root) == fs.join(root, "o", "board"))
end
local function test_falls_back_to_o_board_without_a_matching_sibling()
  local root = make_root("other-origin")
  sibling(root, "https://github.com/someone-else/work")
  assert(run(root) == fs.join(root, "o", "board"))
end
local function test_falls_back_to_o_board_with_no_sibling_at_all()
  local root = make_root("no-sibling")
  assert(run(root) == fs.join(root, "o", "board"))
end
local function test_explicit_gitboard_dir_wins()
  local root = make_root("explicit")
  sibling(root, "https://github.com/cosmic-lua/work")
  local want = fs.join(tmpdir, "explicit-board")
  assert(run(root, env.list({set = {GITBOARD_DIR = want}})) == want)
end
local function test_resolves_the_sibling_of_a_linked_worktrees_main_checkout()
  -- A scratch main checkout with a `../work` sibling, and a linked
  -- worktree under an UNRELATED parent (so its own `../work` does not
  -- exist and only the main-checkout probe can find the sibling).
  local main = make_root("worktree-main")
  local r = check.must(child.run({"git", "init", "-q"}, {cwd = main}))
  assert(r.ok, "git init failed: " .. r.stderr)
  r = check.must(child.run({"git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
        "--allow-empty", "-m", "init"}, {cwd = main}))
  assert(r.ok, "git commit failed: " .. r.stderr)
  local sib = sibling(main, "https://github.com/cosmic-lua/work")
  local wt = fs.join(fs.dirname(main), "elsewhere", "wt", "x")
  r = check.must(child.run({"git", "worktree", "add", "-q", wt, "-b", "wtbranch"},
      {cwd = main}))
  assert(r.ok, "git worktree add failed: " .. r.stderr)
  assert(fs.make_dirs(fs.join(wt, "bin")))
  assert(fs.make_dirs(fs.join(wt, "o", "bootstrap")))
  assert(fs.copy(fs.join(main, "bin", "gitboard"), fs.join(wt, "bin", "gitboard")))
  assert(fs.copy(fs.join(main, "bin", "gitboard.pin"), fs.join(wt, "bin", "gitboard.pin")))
  assert(fs.copy(fs.join(main, "o", "bootstrap", "gitboard"),
      fs.join(wt, "o", "bootstrap", "gitboard")))
  assert(fs.copy(fs.join(main, "o", "bootstrap", "gitboard.pin"),
      fs.join(wt, "o", "bootstrap", "gitboard.pin")))
  assert(run(wt) == sib)
end
