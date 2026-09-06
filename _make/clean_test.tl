#!/usr/bin/env cosmic
--- reads: _make/clean.tl
-- `clean`, and the one thing it must not remove.
--
-- This file asserts clean's behavior through the spawned binary, not
-- through `require`, so the module under test is a real dependency the
-- require graph cannot see -- the declared read above is what puts it
-- in this rule's make prerequisite and the record's content key.
--
-- Split from build_test.tl when that file reached the 500-line cap, on
-- the seam the code already has: `clean` is the one verb about the
-- OUTPUT rather than about the model, and `_make/clean.tl` is its own
-- module for the same reason.
--
-- Like build_test.tl these drive a REAL make over fixture projects.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local child = require("cosmic.child")
local clean = require("_make.clean")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

-- The engine, by the same rule the code uses: COSMIC_MAKE names it,
-- else the copy `--make` extracts from its own binary.
local make_bin = fs.absolute_path(os.getenv("COSMIC_MAKE")
  or "o/make")
-- Skip locally, FAIL in CI. A cold checkout should not fail for lacking
-- a build; CI always provisions the engine, so its absence there means
-- provisioning broke -- and the whole `--make` graph-test surface
-- silently becoming green skips is the failure this guards (029).
check.needs("the make engine at " .. make_bin, fs.is_file(make_bin))

local record Run
  code: integer
  out: string
  err: string
end

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "clean-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.make_dirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  -- A directory is not a project until it says so. Fixtures that
  -- declare a root themselves keep theirs; the rest get the marker
  -- that means "yes, this one" so the fixture tests what it is about.
  if not fs.is_file(fs.join(root, "main.tl"))
  and not fs.is_file(fs.join(root, "main.lua"))
  and not fs.is_file(fs.join(root, ".cosmicignore")) then
    assert(fs.write(fs.join(root, ".cosmicignore"), ""))
  end
  return root
end

--- Run `cosmic --make …` inside dir, with the engine named.
local function make(dir: string, ...: string): Run
  local argv: {string} = {cosmic, "--make"}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "COSMIC_MAKE=" .. make_bin,
    "TMPDIR=" .. tmpdir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  local h = check.must(child.start(argv, {cwd = dir, env = env}))
  local r = check.must(h:wait())
  return {code = r.code or 128, out = r.stdout or "", err = r.stderr or ""}
end

--- Same fixture shape as `_make/build_test.tl`'s `app`.
local function app(name: string): string
  return fixture(name, {
      ["cmd/app/main.tl"] = "local db = require('db')\nprint(db.name())\n",
      ["db/init.tl"] = "local record Db\n  name: function(): string\nend\n" ..
      "local M: Db = {name = function(): string return 'app' end}\nreturn M\n",
      ["db/db_test.tl"] = "local db = require('db')\n" ..
      "assert(db.name() == 'app', 'name')\n",
      ["legacy.lua"] = "return { x = 1 }\n",
      ["schema.sql"] = "CREATE TABLE t(x);\n",
    })
end

-- clean removes o/ in process: driving it through a graph whose rules
-- live in o/ is a knot with no payoff.
local function test_clean_removes_the_build_directory()
  local root = app("clean")
  assert(make(root, "build").code == 0, "build first")
  assert(fs.is_dir(fs.join(root, "o")), "o/ should exist")
  local r = make(root, "clean")
  assert(r.code == 0, "clean should succeed: " .. r.err)
  assert(not fs.is_present(fs.join(root, "o")), "o/ should be gone")
  local again = make(root, "clean")
  assert(again.code == 0, "cleaning a clean tree is not an error")
  assert(again.out:find("nothing to remove", 1, true), "got: " .. again.out)
end

-- ...except the verified bootstrap. `o/bootstrap/cosmic` is the one
-- pinned artifact `bin/cosmic` downloads, checksums and assimilates,
-- and no verb reproduces it: `--make fetch` re-obtains `o/3p`, but
-- this costs a NETWORK. Cleaning a build must not make a project
-- unbuildable offline.
local function test_clean_keeps_the_verified_bootstrap()
  local root = app("cleanboot")
  assert(make(root, "build").code == 0, "build first")
  local boot = fs.join(root, "o/bootstrap")
  assert(fs.make_dirs(boot))
  assert(fs.write(fs.join(boot, "cosmic"), "pretend binary\n"))

  local r = make(root, "clean")
  assert(r.code == 0, "clean should succeed: " .. r.err)
  assert(fs.is_file(fs.join(boot, "cosmic")),
    "the verified bootstrap survives: " .. r.out)
  assert(r.out:find("kept the verified bootstrap", 1, true),
    "and clean says so: " .. r.out)
  assert(not fs.is_present(fs.join(root, "o/bin")),
    "everything else still goes: " .. r.out)
end

-- The pristine sibling and the stamp `bin/cosmic` keeps beside the
-- assimilated bootstrap survive with it: `KEEP` matches `o/bootstrap`
-- by name, whole, so there is no per-file removal decision to get
-- wrong between `cosmic`, `cosmic.ape` and `cosmic.pin` -- one keep
-- covers all three, same as one stamp verifies both binaries.
local function test_clean_keeps_the_pristine_sibling_too()
  local root = app("cleanape")
  assert(make(root, "build").code == 0, "build first")
  local boot = fs.join(root, "o/bootstrap")
  assert(fs.make_dirs(boot))
  assert(fs.write(fs.join(boot, "cosmic"), "pretend assimilated bytes\n"))
  assert(fs.write(fs.join(boot, "cosmic.ape"), "pretend pristine bytes\n"))
  assert(fs.write(fs.join(boot, "cosmic.pin"), "deadbeef\n"))

  local r = make(root, "clean")
  assert(r.code == 0, "clean should succeed: " .. r.err)
  assert(fs.is_file(fs.join(boot, "cosmic")), "the assimilated copy survives")
  assert(fs.is_file(fs.join(boot, "cosmic.ape")), "and the pristine sibling: " .. r.out)
  assert(fs.is_file(fs.join(boot, "cosmic.pin")), "and the stamp naming both: " .. r.out)
end

-- ...and a live git checkout. `skills/work/SKILL.md` has callers run
-- `git clone https://github.com/cosmic-lua/work o/board`, so a
-- checkout root can sit directly under `o/`; clean must not delete it.
-- Detection is the filesystem `.git` marker alone -- a plain file here
-- stands in for a linked worktree's real `gitdir: <path>` marker (the
-- same detection also covers a plain clone's `.git` directory), with
-- no `git` invocation needed to prove the skip.
local function test_clean_keeps_a_git_worktree()
  local root = app("cleanwt")
  assert(make(root, "build").code == 0, "build first")
  local wt = fs.join(root, "o/board")
  assert(fs.make_dirs(wt))
  assert(fs.write(fs.join(wt, ".git"), "gitdir: /elsewhere/.git/worktrees/board\n"))
  assert(fs.write(fs.join(wt, "README.md"), "board contents\n"))

  local r = make(root, "clean")
  assert(r.code == 0, "clean should succeed: " .. r.err)
  assert(fs.is_file(fs.join(wt, "README.md")),
    "the worktree survives: " .. r.out)
  assert(r.out:find("kept board (git worktree)", 1, true),
    "and clean says so: " .. r.out)
  -- The summary detail must name what was ACTUALLY kept: a worktree
  -- only, not the bootstrap it never mentions, so a reader is not told
  -- "kept the verified bootstrap" for a tree that never had one.
  assert(r.out:find("kept 1 git worktree", 1, true),
    "and names the worktree: " .. r.out)
  assert(not r.out:find("bootstrap", 1, true),
    "and does not claim a bootstrap it never kept: " .. r.out)
  assert(not fs.is_present(fs.join(root, "o/bin")),
    "everything else still goes: " .. r.out)
end

-- kept_detail is pure and in-process: direct assertions over every
-- branch rather than another subprocess round-trip through `make`.
local function test_kept_detail_names_nothing_when_nothing_kept()
  assert(clean.kept_detail(false, 0) == "", "got: " .. clean.kept_detail(false, 0))
end

local function test_kept_detail_names_the_bootstrap_alone()
  assert(clean.kept_detail(true, 0) == "the verified bootstrap",
    "got: " .. clean.kept_detail(true, 0))
end

local function test_kept_detail_names_one_worktree_singular()
  assert(clean.kept_detail(false, 1) == "1 git worktree",
    "got: " .. clean.kept_detail(false, 1))
end

local function test_kept_detail_names_many_worktrees_plural()
  assert(clean.kept_detail(false, 3) == "3 git worktrees",
    "got: " .. clean.kept_detail(false, 3))
end

local function test_kept_detail_joins_bootstrap_and_worktrees()
  assert(clean.kept_detail(true, 2) == "the verified bootstrap and 2 git worktrees",
    "got: " .. clean.kept_detail(true, 2))
end

print("all clean tests passed")
