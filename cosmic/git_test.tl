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

--- The refusals a hostile worktree or repository meets: a path through
--- a link, `.git` in another spelling, a linked `.gitmodules`, a HEAD
--- that names a file outside refs/, and an identity that would forge a
--- header line.
local function test_hostile_inputs_are_refused(tmp: string)
  local root = scratch(tmp)
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  assert(Fs.write(tmp .. "/elsewhere/secret", "secret\n"))
  assert(Fs.symlink(tmp .. "/elsewhere", root .. "/linked"))
  local repo = assert(Git.open(root))
  local through, through_why = repo:add({ "linked/secret" })
  assert(through == nil and tostring(through_why):find("symbolic link", 1, true) ~= nil, tostring(through_why))
  for _, path in ipairs({ ".GIT/config", "dir/.Git./x", "GIT~1/config", "dir/../a.txt", "./" }) do
    local got, why = repo:add({ path })
    assert(got == nil, path .. ": " .. tostring(why))
  end
  assert(Fs.symlink("a.txt", root .. "/.gitmodules"))
  local modules, modules_why = repo:add({ ".gitmodules" })
  assert(modules == nil, tostring(modules_why))
  assert(Fs.remove(root .. "/.gitmodules"))
  local forged, forged_why = repo:commit({ message = "forged", allow_empty = true,
    author = { name = "Test", email = "t@example.com>\ncommitter Evil <e@example.com", time = 1, tz = "+0000" } })
  assert(forged == nil and tostring(forged_why):find("identity", 1, true) ~= nil, tostring(forged_why))
  assert(Fs.write(root .. "/.git/HEAD", "ref: refs/../config\n"))
  local head, head_why = repo:head()
  assert(head == nil and tostring(head_why):find("malformed", 1, true) ~= nil, tostring(head_why))
  assert(Fs.write(root .. "/.git/HEAD", "ref: refs/heads/main\n"))
  git(root, { "fsck", "--strict", "--no-dangling" })
end

--- Untracked files match `git status -uall`: ignore rules from
--- `.gitignore` at each level, `info/exclude`, negation, anchors,
--- directory-only rules and `**`, a nested repository, and a tracked
--- file turned into a directory.
local function test_untracked_agrees_with_git(tmp: string)
  local root = scratch(tmp)
  put(root, ".gitignore", "*.log\n!keep.log\nbuild/\n/top-only\ndeep/**/x\n# a comment\n\\#hash\n")
  put(root, "keep.log", "kept\n")
  put(root, "drop.log", "dropped\n")
  put(root, "build/out", "built\n")
  put(root, "top-only", "ignored at the top\n")
  put(root, "dir/top-only", "not ignored below\n")
  put(root, "deep/a/b/x", "ignored\n")
  put(root, "deep/x", "ignored too\n")
  put(root, "deep/y", "kept\n")
  put(root, "#hash", "ignored\n")
  put(root, "dir/.gitignore", "*.tmp\n!/dir-only.tmp\n")
  put(root, "dir/a.tmp", "ignored\n")
  put(root, "dir/dir-only.tmp", "kept\n")
  put(root, "dir-x/excluded", "excluded\n")
  put(root, ".git/info/exclude", "excluded\n")
  put(root, "nested/x.txt", "nested\n")
  git(root .. "/nested", { "init", "-q" })
  assert(Fs.remove(root .. "/a.txt"))
  put(root, "a.txt/inside", "a file where a file was\n")
  local want: mut {string} = {}
  for line in git(root, { "status", "--porcelain=v1", "-uall" }):gmatch("[^\n]+") do
    if line:sub(1, 3) == "?? " then want[#want + 1] = line:sub(4) end
  end
  local status = assert(assert(Git.open(root)):status())
  assert(table.concat(status.untracked, ",") == table.concat(want, ","),
    table.concat(status.untracked, ",") .. " against " .. table.concat(want, ","))
  local unstaged: mut {string} = {}
  for _, c in ipairs(status.unstaged) do unstaged[#unstaged + 1] = c.kind .. " " .. c.path end
  assert(table.concat(unstaged, ",") == "deleted a.txt", table.concat(unstaged, ","))
end

--- Config as git reads it: a value continued over lines, `include`,
--- and `includeIf` on the gitdir and the branch.
local function test_config_includes_agree_with_git(tmp: string)
  local root = scratch(tmp)
  put(root, ".git/extra.inc", "[user]\n\tname = Inc\\\n luded\n")
  put(root, ".git/branch.inc", "[user]\n\temail = branch@example.com\n")
  put(root, ".git/never.inc", "[user]\n\temail = never@example.com\n")
  local config = assert(Fs.read(root .. "/.git/config"))
  assert(Fs.write(root .. "/.git/config", config ..
      "[include]\n\tpath = extra.inc\n" ..
      "[includeIf \"gitdir:" .. Fs.absolute(root)! .. "/\"]\n\tpath = branch.inc\n" ..
      "[includeIf \"onbranch:other\"]\n\tpath = never.inc\n"))
  local repo = assert(Git.open(root))
  put(root, "a.txt", "by an included identity\n")
  assert(repo:add({ "a.txt" }))
  assert(repo:commit({ message = "included" }))
  local want = git(root, { "config", "user.name" }) .. git(root, { "config", "user.email" })
  local got = git(root, { "log", "-1", "--format=%an%n%ae" })
  assert(got == want and got == "Inc luded\nbranch@example.com\n", got .. " against " .. want)
end

--- What git's untracked list leaves out or keeps where it is easy to
--- differ: a .gitignore that is a symbolic link (git reads none), POSIX
--- classes, a bracket left open (it matches nothing), a BOM, and a
--- `.git` file that names no repository (the directory is walked).
local function test_untracked_edge_cases_agree_with_git(tmp: string)
  local root = scratch(tmp)
  put(root, "secret", "*\n")
  put(root, "linked/f", "kept, as git reads no linked .gitignore\n")
  assert(Fs.symlink("../secret", root .. "/linked/.gitignore"))
  put(root, ".gitignore", "\xEF\xBB\xBFbom\n[[:digit:]]x\n[a-\n*[\n[[:nonsense:]]y\n")
  put(root, "bom", "ignored, past the BOM\n")
  put(root, "1x", "ignored\n")
  put(root, "[a-", "kept\n")
  put(root, "a[", "kept\n")
  put(root, "zy", "kept\n")
  put(root, "fake/.git", "gitdir: /nonexistent\n")
  put(root, "fake/f", "listed, as fake is no repository\n")
  local want: mut {string} = {}
  for line in git(root, { "status", "--porcelain=v1", "-uall" }):gmatch("[^\n]+") do
    if line:sub(1, 3) == "?? " then want[#want + 1] = (line:sub(4):gsub('^"(.*)"$', "%1")) end
  end
  local status = assert(assert(Git.open(root)):status())
  assert(table.concat(status.untracked, ",") == table.concat(want, ","),
    table.concat(status.untracked, ",") .. " against " .. table.concat(want, ","))
end

--- A config value as git reads it (CRLF, whitespace in and around
--- quotes, a continuation), a line git refuses, and an `includeIf`
--- gitdir pattern that names the gitdir itself rather than below it.
local function test_config_values_agree_with_git(tmp: string)
  local root = scratch(tmp)
  local base = assert(Fs.read(root .. "/.git/config"))
  local function author(extra: string): string?
    assert(Fs.write(root .. "/.git/config", base .. extra))
    local repo, _ = Git.open(root)
    if repo == nil then return nil end
    put(root, "a.txt", "changed for " .. extra .. "\n")
    assert(repo:add({ "a.txt" }))
    assert(repo:commit({ message = "values" }))
    return git(root, { "log", "-1", "--format=%an" })
  end
  for _, case in ipairs({
      "[user]\r\n\tname = a \\\r\n\tb\r\n",
      "[user]\n\tname = a \\\n\tb\n",
      "[user]\n\tname = \"x  \"  y \t# a comment\n",
      "[user]\n\tname = \"\"  lead\n",
  }) do
    assert(Fs.write(root .. "/.git/config", base .. case))
    local want = git(root, { "config", "user.name" })
    local got = author(case)
    assert(got == want, case .. ": " .. tostring(got) .. " against " .. want)
  end
  for _, case in ipairs({ "[user]\n\tna\\\nme = a\n", "[user\\\n]\n\tname = a\n", "[user]\n\t9name = a\n" }) do
    local got = author(case)
    assert(got == nil, case .. ": read as " .. tostring(got))
  end
  put(root, ".git/i.inc", "[user]\n\tname = Included\n")
  local got = author("[includeIf \"gitdir:./\"]\n\tpath = i.inc\n")
  assert(got == "Test\n", tostring(got))
end
--- A pack whose index cannot be read is skipped: the rest of the store
--- still reads, and a missing object names the skipped pack.
local function test_a_damaged_pack_index_is_skipped(tmp: string)
  local root = scratch(tmp)
  put(root, ".git/objects/pack/pack-0000000000000000000000000000000000000000.idx", "not an index")
  local repo = assert(Git.open(root))
  local first = trimmed(git(root, { "rev-parse", "HEAD~2" }))
  assert(repo:rev("HEAD~2")! == first)
  assert(repo:read(first))
  local _, why = repo:read(string.rep("1", 40))
  assert(tostring(why):find("skipped", 1, true) ~= nil, tostring(why))
end

--- Commit holds the index's lock: while git holds it, commit is
--- refused and leaves the lock and HEAD as they were.
local function test_commit_waits_for_no_index_lock(tmp: string)
  local root = scratch(tmp)
  local head = trimmed(git(root, { "rev-parse", "HEAD" }))
  put(root, ".git/index.lock", "")
  local repo = assert(Git.open(root))
  local made, why = repo:commit({ message = "locked out", allow_empty = true })
  assert(made == nil and tostring(why):find("lock", 1, true) ~= nil, tostring(why))
  assert(Fs.read(root .. "/.git/index.lock")! == "")
  assert(trimmed(git(root, { "rev-parse", "HEAD" })) == head)
  assert(Fs.remove(root .. "/.git/index.lock"))
  assert(repo:commit({ message = "unlocked", allow_empty = true }))
  local lock, _ = Fs.read(root .. "/.git/index.lock")
  assert(lock == nil)
end
