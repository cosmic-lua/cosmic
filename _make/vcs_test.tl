#!/usr/bin/env cosmic
-- The notice line is pure: exact text, no discretion, tested by string
-- equality. The probe is exercised against scratch git repos this file
-- builds itself -- `diverged` reads whatever `origin/main` and HEAD the
-- process's actual working directory names, so each case chdirs into a
-- fixture repo, calls it, and chdirs back.

local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local vcs = require("_make.vcs")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Run one git command in `cwd`, failing the test loudly if it does not
--- exit zero -- fixture setup, not the code under test.
local function git(cwd: string, argv: {string})
  local r = check.must(child.run(argv, {cwd = cwd}))
  assert(r.ok, "git " .. table.concat(argv, " ") .. " failed: " .. r.stderr)
end

--- A fresh, empty git repo with one commit, and nothing else -- no
--- `origin` remote, no `refs/remotes/*` at all.
local function init_repo(name: string): string
  local root = fs.join(tmpdir, "vcs-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  git(root, {"git", "init", "-q"})
  git(root, {"git", "-c", "user.email=test@example.com", "-c",
      "user.name=test", "commit", "--allow-empty", "-q", "-m", "init"})
  return root
end

--- The full sha `ref` names in `cwd`.
local function sha_of(cwd: string, ref: string): string
  local r = check.must(child.run({"git", "rev-parse", ref}, {cwd = cwd}))
  local trimmed = (r.stdout or ""):gsub("%s+$", "")
  return trimmed
end

--- Call `vcs.diverged()` with the process's cwd pointed at `root`,
--- restoring the original cwd before returning -- `diverged` takes no
--- path argument, so this is how a test gives it a repo to read.
local function diverged_in(root: string): string
  local saved = check.must(fs.cwd())
  assert(fs.set_cwd(root))
  local sha = vcs.diverged()
  assert(fs.set_cwd(saved))
  return sha
end

-- `notice` renders the exact line `ci` prints -- no discretion, so this
-- is a string-equality test against the literal the issue specifies.
local function test_notice_line()
  local got = vcs.notice("origin/main", "cca2fb03785b1234567890")
  local want = "ci: HEAD is not a descendant of origin/main " ..
  "(origin/main cca2fb03785b); this gate judged the branch, CI judges " ..
  "the merge"
  assert(got == want, "got: " .. got)
end
test_notice_line()

-- A full sha is 40 characters; the notice shows only the first 12.
local function test_notice_truncates_sha()
  local full = "0123456789abcdef0123456789abcdef01234567"
  local got = vcs.notice("origin/main", full)
  assert(got:find("0123456789ab", 1, true) ~= nil,
    "expected the 12-char prefix in: " .. got)
  assert(got:find(full, 1, true) == nil,
    "the full 40-char sha must not appear: " .. got)
end
test_notice_truncates_sha()

-- No `origin/main` ref at all: `git rev-parse --verify -q origin/main`
-- exits 1, and the probe is silent (nil) -- this is the CI case, where
-- `actions/checkout` only ever fetches the merge ref.
local function test_diverged_missing_ref()
  local root = init_repo("missing-ref")
  local sha = diverged_in(root)
  assert(sha == nil, "no origin/main ref: expected nil, got " .. tostring(sha))
end
test_diverged_missing_ref()

-- `origin/main` resolves and IS an ancestor of HEAD (here, the same
-- commit): not diverged, so the probe is silent.
local function test_diverged_ancestor()
  local root = init_repo("ancestor")
  git(root, {"git", "update-ref", "refs/remotes/origin/main", "HEAD"})
  local sha = diverged_in(root)
  assert(sha == nil,
    "origin/main == HEAD: expected nil (not diverged), got " .. tostring(sha))
end
test_diverged_ancestor()

-- `origin/main` resolves and is NOT an ancestor of HEAD (here, a child
-- commit on another branch): diverged, so the probe returns its sha.
local function test_diverged_true()
  local root = init_repo("diverged")
  git(root, {"git", "branch", "trunk"})
  git(root, {"git", "checkout", "-q", "-b", "feature"})
  git(root, {"git", "-c", "user.email=test@example.com", "-c",
      "user.name=test", "commit", "--allow-empty", "-q", "-m", "feature"})
  local feature_sha = sha_of(root, "HEAD")
  git(root, {"git", "update-ref", "refs/remotes/origin/main", feature_sha})
  git(root, {"git", "checkout", "-q", "trunk"})
  local sha = diverged_in(root)
  assert(sha == feature_sha,
    "expected diverged sha " .. feature_sha .. ", got " .. tostring(sha))
end
test_diverged_true()
