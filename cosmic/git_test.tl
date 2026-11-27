--- cosmic.git against the host's git: a scratch repository that git
--- makes and packs, read and committed to by cosmic.git, then checked by
--- git (`fsck --strict`, `status`, `log`, `rev-parse`). A host with no
--- git skips.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Git = require("cosmic.git")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

--- The host's `git`, which makes the scratch repositories and checks
--- what cosmic.git wrote.
Test.policy{ profiles = { "cosmic" }, env = { "PATH" },
  grants = {
    { path = "/bin/git", letters = "r" }, { path = "/usr/bin/git", letters = "r" } } }

--- Runs git in `root` with no user or system config; raises unless it
--- succeeds and returns what it printed.
local function git(root: string, args: {string}): string
  local found, _ = Proc.find("git")
  if found == nil then Test.skip("no git on PATH") end
  local argv: mut {string} = { found!, "-C", root }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result = assert(Child.run(argv, { stdout = "capture", stderr = "stdout",
    env = { PATH = Env.get("PATH") or "/usr/bin:/bin", HOME = root, GIT_CONFIG_NOSYSTEM = "1",
      GIT_CONFIG_GLOBAL = "/dev/null", LC_ALL = "C" },
    timeout_ns = Clock.seconds(30) }))
  local said = result.stdout!
  assert(result.ok, table.concat(args, " ") .. ": " .. said)
  return said
end

--- Writes `text` at `root`/`path`, making its directories.
local function put(root: string, path: string, text: string)
  local dir = (root .. "/" .. path):match("^(.*)/[^/]*$")
  assert(Fs.mkdirs(dir!))
  assert(Fs.write(root .. "/" .. path, text))
end

--- A repository with two commits on `main`, packed by `gc`, then a third
--- left loose, and a tag on the first.
local function scratch(tmp: string): string
  local root = tmp .. "/repo"
  assert(Fs.mkdirs(root))
  git(root, { "init", "-q", "-b", "main" })
  git(root, { "config", "user.name", "Test" })
  git(root, { "config", "user.email", "test@example.com" })
  put(root, "a.txt", "one\n")
  put(root, "dir/b.txt", "two\n")
  put(root, "dir-x/c.txt", "three\n")
  git(root, { "add", "." })
  git(root, { "commit", "-q", "-m", "first" })
  git(root, { "tag", "-a", "-m", "v1", "v1" })
  put(root, "a.txt", "one\nmore\n")
  git(root, { "commit", "-q", "-am", "second" })
  git(root, { "gc", "-q" })
  put(root, "dir/b.txt", "two\nmore\n")
  git(root, { "commit", "-q", "-am", "third" })
  return root
end

local function trimmed(text: string): string
  return (text:gsub("%s+$", ""))
end

--- Reading agrees with git: HEAD, revisions, the log, the trees.
local function test_read_agrees_with_git(tmp: string)
  local root = scratch(tmp)
  local repo = assert(Git.open(root .. "/dir"))
  assert(repo.worktree == Fs.absolute(root)!, repo.worktree .. " against " .. root)
  assert(repo:head()! == trimmed(git(root, { "rev-parse", "HEAD" })))
  local ref = repo:head_ref()!
  assert(ref == "refs/heads/main", tostring(ref))
  for _, spec in ipairs({ "HEAD~1", "HEAD^", "HEAD~2", "main", "v1", "refs/tags/v1" }) do
    local want = trimmed(git(root, { "rev-parse", spec }))
    local got = repo:rev(spec)!
    assert(got == want, spec .. ": " .. got .. " against " .. want)
  end
  local short = trimmed(git(root, { "rev-parse", "--short=7", "HEAD~1" }))
  assert(repo:rev(short)! == trimmed(git(root, { "rev-parse", "HEAD~1" })))
  local log = assert(repo:log())
  local want_log = trimmed(git(root, { "rev-list", "HEAD" }))
  local got: mut {string} = {}
  for _, c in ipairs(log) do got[#got + 1] = c.oid end
  assert(table.concat(got, "\n") == want_log, table.concat(got, "\n"))
  local newest, oldest = log[1]!, log[3]!
  assert(newest.message == "third\n" and oldest.parents[1] == nil, newest.message)
  assert(newest.author.email == "test@example.com", newest.author.email)
  local tree = assert(repo:tree(newest.tree))
  local names: mut {string} = {}
  for _, entry in ipairs(tree) do names[#names + 1] = entry.mode .. " " .. entry.name end
  assert(table.concat(names, ",") == "100644 a.txt,40000 dir-x,40000 dir", table.concat(names, ","))
  local blob = assert(repo:read(trimmed(git(root, { "rev-parse", "HEAD~2:a.txt" }))))
  assert(blob.kind == "blob" and blob.data == "one\n", blob.data)
  assert(not repo:has(string.rep("0", 40)))
end

--- Status sees what git sees: a staged change, an unstaged edit and a
--- deletion.
local function test_status_agrees_with_git(tmp: string)
  local root = scratch(tmp)
  put(root, "a.txt", "staged\n")
  git(root, { "add", "a.txt" })
  put(root, "dir/b.txt", "edited\n")
  assert(Fs.remove(root .. "/dir-x/c.txt"))
  local status = assert(assert(Git.open(root)):status())
  assert(status.branch == "main", tostring(status.branch))
  assert(#status.staged == 1 and status.staged[1].path == "a.txt" and status.staged[1].kind == "modified")
  local unstaged: mut {string} = {}
  for _, c in ipairs(status.unstaged) do unstaged[#unstaged + 1] = c.kind .. " " .. c.path end
  assert(table.concat(unstaged, ",") == "deleted dir-x/c.txt,modified dir/b.txt", table.concat(unstaged, ","))
end

--- Add and commit make a commit git accepts: fsck is clean, status is
--- clean, and HEAD, the log and the reflog name the new commit.
local function test_commit_is_one_git_accepts(tmp: string)
  local root = scratch(tmp)
  put(root, "a.txt", "changed\n")
  put(root, "dir/new/d.txt", "added\n")
  put(root, "dir.txt", "sorts between dir and dir-x\n")
  assert(Fs.remove(root .. "/dir-x/c.txt"))
  local repo = assert(Git.open(root))
  assert(repo:add({ "a.txt", "dir/new/d.txt", "dir.txt", "dir-x/c.txt" }))
  local oid = assert(repo:commit({ message = "made by cosmic.git" }))
  git(root, { "fsck", "--strict", "--no-dangling" })
  assert(git(root, { "status", "--porcelain" }) == "", git(root, { "status", "--porcelain" }))
  assert(trimmed(git(root, { "rev-parse", "HEAD" })) == oid)
  local said = git(root, { "log", "-1", "--format=%s%n%an <%ae>" })
  assert(said == "made by cosmic.git\nTest <test@example.com>\n", said)
  assert(trimmed(git(root, { "diff", "--name-status", "HEAD~1", "HEAD" })) ==
      "M\ta.txt\nD\tdir-x/c.txt\nA\tdir.txt\nA\tdir/new/d.txt")
  assert(git(root, { "reflog", "-1", "--format=%gs" }) == "commit: made by cosmic.git\n")
  assert(git(root, { "show", "HEAD:dir/new/d.txt" }) == "added\n")
  -- git reads the index cosmic.git wrote, and commits on top of it.
  put(root, "a.txt", "by git\n")
  git(root, { "commit", "-q", "-am", "after" })
  assert(trimmed(git(root, { "rev-parse", "HEAD~1" })) == oid)
end

--- The first commit of an unborn branch has no parent and an initial
--- reflog line.
local function test_first_commit_of_an_empty_repository(tmp: string)
  local root = tmp .. "/empty"
  assert(Fs.mkdirs(root))
  git(root, { "init", "-q", "-b", "trunk" })
  git(root, { "config", "user.name", "Test" })
  git(root, { "config", "user.email", "test@example.com" })
  put(root, "x.txt", "x\n")
  local repo = assert(Git.open(root))
  assert(repo:head()! == false)
  assert(repo:add({ "x.txt" }))
  local oid = assert(repo:commit({ message = "root" }))
  git(root, { "fsck", "--strict" })
  assert(trimmed(git(root, { "rev-parse", "trunk" })) == oid)
  assert(git(root, { "reflog", "-1", "--format=%gs" }) == "commit (initial): root\n")
end

--- What it refuses: an empty commit, a directory to add, a path in
--- `.git` or outside, a repository with an extension it does not know.
local function test_refusals(tmp: string)
  local root = scratch(tmp)
  local repo = assert(Git.open(root))
  local none, none_why = repo:commit({ message = "nothing" })
  assert(none == nil and tostring(none_why):find("nothing", 1, true) ~= nil, tostring(none_why))
  assert(repo:commit({ message = "empty on purpose", allow_empty = true }))
  git(root, { "fsck", "--strict", "--no-dangling" })
  local dir, dir_why = repo:add({ "dir" })
  assert(dir == nil, tostring(dir_why))
  local inside, inside_why = repo:add({ ".git/config" })
  assert(inside == nil, tostring(inside_why))
  local outside, outside_why = repo:add({ "../elsewhere" })
  assert(outside == nil, tostring(outside_why))
  local alone, alone_why = Git.open(tmp)
  assert(alone == nil, tostring(alone_why))
  git(root, { "config", "core.repositoryformatversion", "1" })
  git(root, { "config", "extensions.unheardof", "true" })
  local strange, strange_why = Git.open(root)
  assert(strange == nil and tostring(strange_why):find("unheardof", 1, true) ~= nil, tostring(strange_why))
end
