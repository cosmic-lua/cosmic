--- Makes testdata/git/scratch again with the git program, for cosmic/git_test.tl, which reads it with no git on PATH.
--- Run from the top of a checkout: `bin/cosmic - < testdata/git/record.tl`. Names and dates are fixed, so each run makes
--- the same objects, and the ids the tests hold stay right; a newer git may pack them in another order.
---
--- The repository has two commits on `main` packed by `gc`, a third left loose, and an annotated tag `v1` on the
--- first. Its `.git` is kept as `dotgit`, since git keeps no `.git` directory in a tree it tracks; the tests copy
--- the scratch tree and rename it.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local out = "testdata/git/scratch"
local found, _ = Proc.find("git")
local program = assert(found, "no git on PATH")
local work = assert(Fs.mkdtemp("git-record-"))
local root = work .. "/repo"
local tick = 1767225600

--- Runs git in `root`, as a commit `tick` seconds past the epoch, with no user or system config.
local function git(args: {string})
  local argv: mut {string} = { program, "-C", root, "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false" }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local date = tostring(tick) .. " +0000"
  local result = assert(Child.run(argv, { stdout = "capture", stderr = "stdout",
    env = { PATH = Env.get("PATH") or "/usr/bin:/bin", HOME = work, GIT_CONFIG_NOSYSTEM = "1",
      GIT_CONFIG_GLOBAL = "/dev/null", LC_ALL = "C", GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date },
    timeout_ns = Clock.seconds(30) }))
  assert(result.ok, table.concat(args, " ") .. ": " .. tostring(result.stdout))
end

local function put(path: string, text: string)
  assert(Fs.mkdirs(Fs.dirname(root .. "/" .. path)))
  assert(Fs.write(root .. "/" .. path, text))
end

assert(Fs.mkdirs(root))
git({ "init", "-q", "-b", "main" })
git({ "config", "user.name", "Test" })
git({ "config", "user.email", "test@example.com" })
put("a.txt", "one\n")
put("dir/b.txt", "two\n")
put("dir-x/c.txt", "three\n")
git({ "add", "." })
git({ "commit", "-q", "-m", "first" })
git({ "tag", "-a", "-m", "v1", "v1" })
tick = tick + 60
put("a.txt", "one\nmore\n")
git({ "commit", "-q", "-am", "second" })
git({ "gc", "-q" })
tick = tick + 60
put("dir/b.txt", "two\nmore\n")
git({ "commit", "-q", "-am", "third" })
-- What git init leaves that no test reads.
for _, name in ipairs({ "hooks", "description", "COMMIT_EDITMSG", "ORIG_HEAD", "logs", "info/refs",
    "objects/info/packs", "objects/info/commit-graph" }) do
  local status = assert(Fs.status(root .. "/.git/" .. name))
  if status.exists then assert(Fs.remove_tree(root .. "/.git/" .. name)) end
end
assert(Fs.rename(root .. "/.git", root .. "/dotgit"))
assert(Fs.remove_tree(out))
assert(Fs.copy_tree(root, out))
assert(Fs.remove_tree(work))
print("made " .. out)
