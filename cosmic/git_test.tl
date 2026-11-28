--- cosmic.git on a repository the git program made once and that is
--- kept in testdata/git/scratch (testdata/git/record.tl makes it
--- again). The tests run no git: what git said of that repository, and
--- of the commits these tests make with fixed names and dates, is held
--- here as literals.

local Fs = require("cosmic.fs")
local Git = require("cosmic.git")
local Test = require("cosmic.test")
local Bench = require("cosmic.bench")

Test.policy{ grants = { { path = "testdata/git", letters = "r" } } }

--- HEAD, HEAD~1 and HEAD~2 of the scratch repository, its tag `v1`
--- (an annotated tag, so its own object) and HEAD~2's a.txt.
local THIRD <const> = "3ab7507e4992b4aa44687aecc2574bb09d6cf168"
local SECOND <const> = "b3209d672ef8550a275cec65a026cb24b8df9ca0"
local FIRST <const> = "f0f5f8b007a63964697ba58b7f7b0119a6b800f6"
local TAG <const> = "282b19966d72a810b3332c2f7f2305c8934d14ea"
local FIRST_A <const> = "5626abf0f72e58d7a153368ba57db4c673c0e171"

--- The identity of the commits these tests make, so git's ids for them
--- are known.
local WHO <const>: Git.Person = { name = "Test", email = "test@example.com", time = 1767225900, tz = "+0000" }

--- Writes `text` at `root`/`path`, making its directories.
local function put(root: string, path: string, text: string)
  assert(Fs.mkdirs(Fs.dirname(root .. "/" .. path)))
  assert(Fs.write(root .. "/" .. path, text))
end

--- A copy of the scratch repository at `tmp`/repo: two commits on
--- `main`, packed, a third left loose, and a tag on the first.
local function scratch(tmp: string): string
  local root = tmp .. "/repo"
  assert(Fs.copy_tree("testdata/git/scratch", root))
  assert(Fs.rename(root .. "/dotgit", root .. "/.git"))
  return root
end

--- An empty repository at `root` whose HEAD names `branch`, as
--- `git init` makes one, with the scratch identity.
local function empty(root: string, branch: string)
  put(root, ".git/HEAD", "ref: refs/heads/" .. branch .. "\n")
  put(root, ".git/config", "[core]\n\trepositoryformatversion = 0\n\tbare = false\n" ..
      "[user]\n\tname = Test\n\temail = test@example.com\n")
  assert(Fs.mkdirs(root .. "/.git/objects"))
  assert(Fs.mkdirs(root .. "/.git/refs/heads"))
end

--- The oid at `path` (slash-separated) under the tree `tree`.
local function at(repo: Git.Repo, tree: string, path: string): string?
  local oid = tree
  for name in path:gmatch("[^/]+") do
    local found: string? = nil
    for _, entry in ipairs(assert(repo:tree(oid))) do
      if entry.name == name then found = entry.oid end
    end
    if found == nil then return nil end
    oid = found
  end
  return oid
end

--- The author of HEAD, as `name <email>`.
local function author(root: string): string
  local commits = assert(assert(Git.open(root)):log({ limit = 1 }))
  local who = commits[1]!.author
  return who.name .. " <" .. who.email .. ">"
end

local function clean(status: Git.Status): boolean
  return #status.staged == 0 and #status.unstaged == 0 and #status.untracked == 0
end

--- Reading agrees with git: HEAD, revisions, the log, the trees.
local function test_read_agrees_with_git(tmp: string)
  local root = scratch(tmp)
  local repo = assert(Git.open(root .. "/dir"))
  assert(repo.worktree == Fs.absolute(root)!, repo.worktree .. " against " .. root)
  assert(repo:head()! == THIRD)
  local ref = repo:head_ref()!
  assert(ref == "refs/heads/main", tostring(ref))
  for _, case in ipairs({ { "HEAD~1", SECOND }, { "HEAD^", SECOND }, { "HEAD~2", FIRST }, { "main", THIRD },
      { "v1", TAG }, { "refs/tags/v1", TAG }, { SECOND:sub(1, 7), SECOND } }) do
    local spec, want = case[1]!, case[2]!
    local got = repo:rev(spec)!
    assert(got == want, spec .. ": " .. got .. " against " .. want)
  end
  local log = assert(repo:log())
  local got: mut {string} = {}
  for _, c in ipairs(log) do got[#got + 1] = c.oid end
  assert(table.concat(got, ",") == THIRD .. "," .. SECOND .. "," .. FIRST, table.concat(got, ","))
  local newest, oldest = log[1]!, log[3]!
  assert(newest.message == "third\n" and oldest.parents[1] == nil, newest.message)
  assert(newest.author.email == "test@example.com", newest.author.email)
  local tree = assert(repo:tree(newest.tree))
  local names: mut {string} = {}
  for _, entry in ipairs(tree) do names[#names + 1] = entry.mode .. " " .. entry.name end
  assert(table.concat(names, ",") == "100644 a.txt,40000 dir-x,40000 dir", table.concat(names, ","))
  assert(at(repo, oldest.tree, "a.txt") == FIRST_A)
  local blob = assert(repo:read(FIRST_A))
  assert(blob.kind == "blob" and blob.data == "one\n", blob.data)
  assert(not repo:has(string.rep("0", 40)))
end

--- Status sees a staged change, an unstaged edit and a deletion.
local function test_status_agrees_with_git(tmp: string)
  local root = scratch(tmp)
  local repo = assert(Git.open(root))
  assert(clean(assert(repo:status())))
  put(root, "a.txt", "staged\n")
  assert(repo:add({ "a.txt" }))
  put(root, "dir/b.txt", "edited\n")
  assert(Fs.remove(root .. "/dir-x/c.txt"))
  local status = assert(repo:status())
  assert(status.branch == "main", tostring(status.branch))
  assert(#status.staged == 1 and status.staged[1].path == "a.txt" and status.staged[1].kind == "modified")
  local unstaged: mut {string} = {}
  for _, c in ipairs(status.unstaged) do unstaged[#unstaged + 1] = c.kind .. " " .. c.path end
  assert(table.concat(unstaged, ",") == "deleted dir-x/c.txt,modified dir/b.txt", table.concat(unstaged, ","))
end

--- `ignored` lists what the tree's own `.gitignore` files ignore: files by path, a whole directory once as `dir/`, a
--- tracked file never, and a rule a deeper file negates not at all. No `info/exclude` is read.
local function test_ignored_lists_what_the_trees_gitignore_files_ignore(tmp: string)
  local root = scratch(tmp)
  put(root, ".gitignore", "*.log\nout/\n")
  put(root, "dir/.gitignore", "!keep.log\n")
  put(root, "x.log", "x\n")
  put(root, "dir/y.log", "y\n")
  put(root, "dir/keep.log", "k\n")
  put(root, "out/gen.txt", "g\n")
  put(root, "src/other.txt", "o\n")
  assert(Fs.write(root .. "/.git/info/exclude", "src/\n"))
  put(root, "vendor/lib/a.log", "nested\n")
  assert(Fs.mkdirs(root .. "/vendor/lib/.git/objects"))
  assert(Fs.mkdirs(root .. "/vendor/lib/.git/refs"))
  put(root, "vendor/lib/.git/HEAD", "ref: refs/heads/main\n")
  local repo = assert(Git.open(root, true))
  local found = assert(repo:ignored())
  assert(table.concat(found, ",") == "dir/y.log,out/,x.log", table.concat(found, ","))
end

--- Add and commit make the commit git makes of the same change with the
--- same names and dates: the same id, so the same bytes in each object.
--- Status is clean after it, HEAD's reflog names it, and a second
--- commit reads the index the first wrote.
local function test_commit_is_one_git_accepts(tmp: string)
  local root = scratch(tmp)
  put(root, "a.txt", "changed\n")
  put(root, "dir/new/d.txt", "added\n")
  put(root, "dir.txt", "sorts between dir and dir-x\n")
  assert(Fs.remove(root .. "/dir-x/c.txt"))
  local repo = assert(Git.open(root))
  assert(repo:add({ "a.txt", "dir/new/d.txt", "dir.txt", "dir-x/c.txt" }))
  local oid = assert(repo:commit({ message = "made by cosmic.git", author = WHO, committer = WHO }))
  assert(oid == "4afaf17e8a8dd182ebd58047766757406b6b4fdc", oid)
  local made = assert(repo:commit_info(oid))
  assert(made.tree == "ed90be39df3b0bed713c95135719991dda99ec3f", made.tree)
  assert(made.parents[1] == THIRD)
  assert(clean(assert(repo:status())))
  assert(repo:head()! == oid)
  local blob = assert(repo:read(at(repo, made.tree, "dir/new/d.txt")!))
  assert(blob.data == "added\n", blob.data)
  local reflog = assert(Fs.read(root .. "/.git/logs/HEAD"))
  assert(reflog:find(THIRD .. " " .. oid .. " Test <test@example.com> 1767225900 +0000\tcommit: made by cosmic.git\n", 1,
    true) ~= nil, reflog)
  put(root, "a.txt", "again\n")
  assert(repo:add({ "a.txt" }))
  local after = assert(repo:commit({ message = "after", author = WHO, committer = WHO }))
  assert(repo:rev("HEAD~1")! == oid and repo:head()! == after)
end

--- `merge_base` names the newest commit two histories share, `is_shallow` reads the `shallow` file, and `files` lists
--- every file of a commit by its path.
local function test_merge_base_shallow_and_files(tmp: string)
  local root = scratch(tmp)
  local repo = assert(Git.open(root))
  assert(repo:merge_base("HEAD", "HEAD~2")! == FIRST)
  assert(repo:merge_base("HEAD~2", "HEAD")! == FIRST)
  assert(repo:merge_base("HEAD", "HEAD")! == THIRD)
  -- A branch that left at the second commit, and a commit on main after it.
  put(root, ".git/refs/heads/side", SECOND .. "\n")
  put(root, "a.txt", "main moved\n")
  assert(repo:add({ "a.txt" }))
  local moved = assert(repo:commit({ message = "moved", author = WHO, committer = WHO }))
  assert(repo:merge_base("main", "side")! == SECOND)
  assert(repo:merge_base("side", moved)! == SECOND)
  assert(not repo:is_shallow())
  put(root, ".git/shallow", FIRST .. "\n")
  local cut = assert(Git.open(root))
  assert(cut:is_shallow())
  local files = assert(repo:files("HEAD~3"))
  assert(files["a.txt"]!.oid == FIRST_A and files["a.txt"]!.mode == "100644" and files["a.txt"]!.name == "a.txt")
  local now = assert(repo:files("HEAD"))
  assert(now["dir/b.txt"] ~= nil and now["dir-x/c.txt"] ~= nil and now["dir"] == nil)
  local refused, _ = repo:merge_base("HEAD", "no-such-branch")
  assert(refused == nil)
end

--- The first commit of an unborn branch has no parent and an initial
--- reflog line.
local function test_first_commit_of_an_empty_repository(tmp: string)
  local root = tmp .. "/empty"
  empty(root, "trunk")
  put(root, "x.txt", "x\n")
  local repo = assert(Git.open(root))
  assert(repo:head()! == false)
  assert(repo:add({ "x.txt" }))
  local oid = assert(repo:commit({ message = "root", author = WHO, committer = WHO }))
  assert(oid == "62db62a29621bbcfca3f6c6c42e710d0a120c510", oid)
  assert(repo:rev("trunk")! == oid)
  local reflog = assert(Fs.read(root .. "/.git/logs/HEAD"))
  assert(reflog:find("\tcommit (initial): root\n", 1, true) ~= nil, reflog)
end

--- What it refuses: an empty commit, a directory to add, a path in
--- `.git` or outside, a repository with an extension it does not know.
local function test_refusals(tmp: string)
  local root = scratch(tmp)
  local repo = assert(Git.open(root))
  local none, none_why = repo:commit({ message = "nothing" })
  assert(none == nil and tostring(none_why):find("nothing", 1, true) ~= nil, tostring(none_why))
  local empty_oid = assert(repo:commit({ message = "empty on purpose", allow_empty = true }))
  local made = assert(repo:commit_info(empty_oid))
  assert(made.tree == assert(repo:commit_info(THIRD)).tree and made.parents[1] == THIRD)
  local dir, dir_why = repo:add({ "dir" })
  assert(dir == nil, tostring(dir_why))
  local inside, inside_why = repo:add({ ".git/config" })
  assert(inside == nil, tostring(inside_why))
  local outside, outside_why = repo:add({ "../elsewhere" })
  assert(outside == nil, tostring(outside_why))
  local alone, alone_why = Git.open(tmp)
  assert(alone == nil, tostring(alone_why))
  local config = assert(Fs.read(root .. "/.git/config"))
  assert(Fs.write(root .. "/.git/config", (config:gsub("repositoryformatversion = 0", "repositoryformatversion = 1")) ..
      "[extensions]\n\tunheardof = true\n"))
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
  assert(repo:head()! == THIRD)
end

--- Untracked files as `git status -uall` lists them: ignore rules from
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
  empty(root .. "/nested", "main")
  assert(Fs.remove(root .. "/a.txt"))
  put(root, "a.txt/inside", "a file where a file was\n")
  local status = assert(assert(Git.open(root)):status())
  local want = ".gitignore,a.txt/inside,deep/y,dir/.gitignore,dir/dir-only.tmp,dir/top-only,keep.log,nested/"
  assert(table.concat(status.untracked, ",") == want, table.concat(status.untracked, ","))
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
  local got = author(root)
  assert(got == "Inc luded <branch@example.com>", got)
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
  local status = assert(assert(Git.open(root)):status())
  local want = ".gitignore,[a-,a[,fake/f,linked/.gitignore,linked/f,secret,zy"
  assert(table.concat(status.untracked, ",") == want, table.concat(status.untracked, ","))
end

--- A config value as git 2.46 and later reads it (CRLF, whitespace in
--- and around quotes, a continuation), a line git refuses, and an
--- `includeIf` gitdir pattern that names the gitdir itself rather than
--- below it. (Before 2.46, git read each whitespace byte between words
--- as one space.)
local function test_config_values_agree_with_git(tmp: string)
  local root = scratch(tmp)
  local base = assert(Fs.read(root .. "/.git/config"))
  local function name(extra: string): string?
    assert(Fs.write(root .. "/.git/config", base .. extra))
    local repo, _ = Git.open(root)
    if repo == nil then return nil end
    put(root, "a.txt", "changed for " .. extra .. "\n")
    assert(repo:add({ "a.txt" }))
    assert(repo:commit({ message = "values" }))
    return author(root)
  end
  for _, case in ipairs({
      { "[user]\r\n\tname = a \\\r\n\tb\r\n", "a \tb" },
      { "[user]\n\tname = a \\\n\tb\n", "a \tb" },
      { "[user]\n\tname = \"x  \"  y \t# a comment\n", "x    y" },
      { "[user]\n\tname = \"\"  lead\n", "lead" },
  }) do
    local config, want = case[1]!, case[2]! .. " <test@example.com>"
    local got = name(config)
    assert(got == want, (config:gsub("\n", "\\n")) .. ": " .. tostring(got) .. " against " .. want)
  end
  for _, case in ipairs({ "[user]\n\tna\\\nme = a\n", "[user\\\n]\n\tname = a\n", "[user]\n\t9name = a\n" }) do
    local got = name(case)
    assert(got == nil, case .. ": read as " .. tostring(got))
  end
  put(root, ".git/i.inc", "[user]\n\tname = Included\n")
  local got = name("[includeIf \"gitdir:./\"]\n\tpath = i.inc\n")
  assert(got == "Test <test@example.com>", tostring(got))
end

--- A pack whose index cannot be read is skipped: the rest of the store
--- still reads, and a missing object names the skipped pack.
local function test_a_damaged_pack_index_is_skipped(tmp: string)
  local root = scratch(tmp)
  put(root, ".git/objects/pack/pack-0000000000000000000000000000000000000000.idx", "not an index")
  local repo = assert(Git.open(root))
  assert(repo:rev("HEAD~2")! == FIRST)
  assert(repo:read(FIRST))
  local _, why = repo:read(string.rep("1", 40))
  assert(tostring(why):find("skipped", 1, true) ~= nil, tostring(why))
end

--- Commit holds the index's lock: while git holds it, commit is
--- refused and leaves the lock and HEAD as they were.
local function test_commit_waits_for_no_index_lock(tmp: string)
  local root = scratch(tmp)
  put(root, ".git/index.lock", "")
  local repo = assert(Git.open(root))
  local made, why = repo:commit({ message = "locked out", allow_empty = true })
  assert(made == nil and tostring(why):find("lock", 1, true) ~= nil, tostring(why))
  assert(Fs.read(root .. "/.git/index.lock")! == "")
  assert(repo:head()! == THIRD)
  assert(Fs.remove(root .. "/.git/index.lock"))
  assert(repo:commit({ message = "unlocked", allow_empty = true }))
  local lock, _ = Fs.read(root .. "/.git/index.lock")
  assert(lock == nil)
end

--- A repository whose `index.version` is 4 keeps it: `add` writes version 4 with prefix-compressed paths, and the
--- index reads back, so status is clean and a commit holds every path.
local function test_index_version_4_round_trips(tmp: string)
  local root = tmp .. "/v4"
  empty(root, "main")
  local config = assert(Fs.read(root .. "/.git/config"))
  put(root, ".git/config", config .. "[index]\n\tversion = 4\n")
  put(root, "dir/sub/one.txt", "1\n")
  put(root, "dir/sub/two.txt", "2\n")
  put(root, "dir/subx.txt", "3\n")
  put(root, "a.txt", "a\n")
  local repo = assert(Git.open(root))
  assert(repo:add({ "dir/sub/one.txt", "dir/sub/two.txt", "dir/subx.txt", "a.txt" }))
  local raw = assert(Fs.read(root .. "/.git/index"))
  assert(raw:sub(1, 8) == "DIRC\0\0\0\4", "not index version 4")
  local again = assert(Git.open(root))
  local before = assert(again:status())
  assert(#before.staged == 4 and #before.unstaged == 0, "staged " .. tostring(#before.staged))
  local oid = assert(again:commit({ message = "v4", author = WHO, committer = WHO }))
  local made = assert(again:commit_info(oid))
  assert(at(again, made.tree, "dir/sub/two.txt") ~= nil)
  assert(at(again, made.tree, "dir/subx.txt") ~= nil)
  -- A later add keeps the version it read.
  put(root, "dir/sub/one.txt", "changed\n")
  assert(again:add({ "dir/sub/one.txt" }))
  assert(assert(Fs.read(root .. "/.git/index")):sub(1, 8) == "DIRC\0\0\0\4")
  assert(clean(assert(assert(Git.open(root)):status())) == false)
  assert(#assert(assert(Git.open(root)):status()).staged == 1)
end

--- A file that git would convert or filter on `add` is one cosmic.git refuses: it cannot run the filter, and
--- recording the raw bytes would store what git would not.
local function test_add_refuses_what_a_filter_would_change(tmp: string)
  local root = scratch(tmp)
  put(root, ".gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n*.id ident\n")
  put(root, "big.bin", "payload\n")
  put(root, "tag.id", "$Id$\n")
  put(root, "plain.txt", "fine\n")
  local repo = assert(Git.open(root))
  local made, why = repo:add({ "big.bin" })
  assert(made == nil and tostring(why):find("big.bin", 1, true) ~= nil, tostring(why))
  made, why = repo:add({ "tag.id" })
  assert(made == nil and tostring(why):find("tag.id", 1, true) ~= nil, tostring(why))
  assert(repo:add({ "plain.txt" }))
  -- A nested file overrides the root's line, as git ranks them.
  put(root, "sub/.gitattributes", "*.bin -filter\n")
  put(root, "sub/ok.bin", "raw\n")
  assert(repo:add({ "sub/ok.bin" }))
  -- core.autocrlf converts a file holding CR, so a CRLF file is refused and an LF file is not.
  local config = assert(Fs.read(root .. "/.git/config"))
  put(root, ".git/config", config .. "[core]\n\tautocrlf = true\n")
  put(root, "win.txt", "a\r\nb\r\n")
  put(root, "unix.txt", "a\nb\n")
  local crlf = assert(Git.open(root))
  made, why = crlf:add({ "win.txt" })
  assert(made == nil and tostring(why):find("win.txt", 1, true) ~= nil, tostring(why))
  assert(crlf:add({ "unix.txt" }))
  -- Auto mode leaves a file it takes for binary (a lone CR).
  put(root, "lone.txt", "a\rb\n")
  assert(crlf:add({ "lone.txt" }))
end

--- Benches. A copy of the scratch repository with 100 files more and 30 commits more on `main`, each of one changed
--- file: opening it, `status`, `log`, a revision, the packed first commit's tree and a blob of it, and an add and a
--- commit.

--- The bench repository at `dir`/repo, and the repository open.
local function sample_repo(dir: string): (string, Git.Repo)
  local root = scratch(dir)
  local repo = assert(Git.open(root))
  local paths: mut {string} = {}
  for i = 1, 100 do
    local path = "f" .. tostring(i) .. ".txt"
    put(root, path, "file " .. tostring(i) .. "\n")
    paths[#paths + 1] = path
  end
  assert(repo:add(paths))
  assert(repo:commit({ message = "files", author = WHO, committer = WHO }))
  for i = 1, 30 do
    put(root, "f1.txt", "edit " .. tostring(i) .. "\n")
    assert(repo:add({ "f1.txt" }))
    assert(repo:commit({ message = "edit", author = WHO, committer = WHO }))
  end
  return root, repo
end

local function bench_open(b: Bench.B)
  local root = sample_repo(b.dir)
  b.reset()
  for _ = 1, b.n do assert(Git.open(root)) end
end

local function bench_rev_head_10(b: Bench.B)
  local _, repo = sample_repo(b.dir)
  b.reset()
  for _ = 1, b.n do assert(repo:rev("HEAD~10")) end
end

local function bench_log_all(b: Bench.B)
  local _, repo = sample_repo(b.dir)
  b.reset()
  for _ = 1, b.n do assert(repo:log({ limit = 200 })) end
end

local function bench_status(b: Bench.B)
  local _, repo = sample_repo(b.dir)
  b.reset()
  for _ = 1, b.n do assert(repo:status()) end
end

--- The tree of the repository's first commit, which is in its pack, and a blob of that tree.
local function packed(repo: Git.Repo): (string, string)
  local commits = assert(repo:log({ limit = 200 }))
  local tree = commits[#commits]!.tree
  local blob = ""
  for _, entry in ipairs(assert(repo:tree(tree))) do
    if entry.mode == "100644" then blob = entry.oid end
  end
  assert(blob ~= "", "the first tree holds no file")
  return tree, blob
end

local function bench_read_tree(b: Bench.B)
  local _, repo = sample_repo(b.dir)
  local tree = packed(repo)
  b.reset()
  for _ = 1, b.n do assert(repo:tree(tree)) end
end

local function bench_read_blob(b: Bench.B)
  local _, repo = sample_repo(b.dir)
  local _, blob = packed(repo)
  b.reset()
  for _ = 1, b.n do assert(repo:read(blob)) end
end

local function bench_add_and_commit(b: Bench.B)
  local root, repo = sample_repo(b.dir)
  b.reset()
  for i = 1, b.n do
    put(root, "f2.txt", "edit " .. tostring(i) .. "\n")
    assert(repo:add({ "f2.txt" }))
    assert(repo:commit({ message = "edit", author = WHO, committer = WHO }))
  end
end
