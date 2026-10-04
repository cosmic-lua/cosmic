--- `cosmic todos` over a git repository of its own: blame recorded at one
--- `HEAD` carries on to the next for every file the commits between them
--- leave alone. It starts the system's git, so it is a module of its own:
--- build/todos_test.tl's trees are in no repository and start none.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local todos = require("build.todos")
local work = require("build.work")

--- The system's git.
-- TODO: name git by what PATH finds rather than the whole of the
-- system's paths, once a declaration can name a program (`processes` by
-- name, which the sandbox resolves, with what its loader reads): on a
-- host with git elsewhere (/nix/store, /opt), the tests that build a
-- repository pass over it.
Test.needs{ system = true }

--- Lines joined into one file's text, so no line of this file opens
--- with a comment marker and is listed itself.
local function text(lines: {string}): string
  return table.concat(lines, "\n") .. "\n"
end

--- Runs git in `root`, for a test that builds a repository of its own.
local function git_in(root: string, args: {string}): boolean
  local argv: {string} = { assert(Proc.find("git")), "-C", root, "-c", "user.name=t",
    "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false" }
  for _, each in ipairs(args) do
    argv[#argv + 1] = each
  end
  local result = Child.run(argv, { stdin = "null",
    stdout = "null", stderr = "null" })
  return result ~= nil and result.ok
end

local function test_blame_carries_across_commits_that_leave_a_file_alone()
  local root = assert(Fs.mkdtemp("cosmic-todos-test-"))
  if not git_in(root, { "init", "-q" }) then
    assert(Fs.remove_tree(root))
    return
  end
  assert(Fs.write(root .. "/a.tl", text({ "-- TODO: first" })))
  assert(Fs.write(root .. "/b.tl", text({ "-- TODO: second" })))
  assert(git_in(root, { "add", "." }))
  assert(git_in(root, { "commit", "-q", "-m", "one" }))
  local handle = assert(work.open(root))
  local function listed(): {todos.Todo}, integer
    assert(work.stage(handle, false))
    local listing = assert(todos.list(handle.db, root))
    return listing.todos, listing.blamed
  end
  local all, blamed = listed()
  assert(blamed == 2, "blamed " .. blamed)
  assert(all[1].commit ~= "" and all[1].summary == "one", all[1].summary)

  -- A commit that touches neither file blames neither again.
  assert(Fs.write(root .. "/c.tl", text({ "local c = 3" })))
  assert(git_in(root, { "add", "c.tl" }))
  assert(git_in(root, { "commit", "-q", "-m", "two" }))
  all, blamed = listed()
  assert(blamed == 0, "blamed " .. blamed)
  assert(all[2].summary == "one", all[2].summary)

  -- One that touches a file blames that file alone.
  assert(Fs.write(root .. "/b.tl", text({ "-- TODO: second, reworded" })))
  assert(git_in(root, { "commit", "-q", "-am", "three" }))
  all, blamed = listed()
  assert(blamed == 1, "blamed " .. blamed)
  assert(all[1].summary == "one" and all[2].summary == "three", all[2].summary)

  -- A rewritten history may have dropped the commits a row names.
  assert(git_in(root, { "commit", "-q", "--amend", "-m", "three again" }))
  all, blamed = listed()
  assert(blamed == 2, "blamed " .. blamed)
  assert(all[2].summary == "three again", all[2].summary)
  assert(work.close(handle))
  assert(Fs.remove_tree(root))
end

--- A commit the tree's `.git-blame-ignore-revs` lists is passed over: a
--- line it rewrote is blamed on the commit before it, once the file is
--- there, even for a file blamed at an earlier `HEAD`. A link in the
--- TODO is listed as its code span.
local function test_blame_passes_over_the_commits_the_tree_ignores()
  local root = assert(Fs.mkdtemp("cosmic-todos-test-"))
  if not git_in(root, { "init", "-q" }) then
    assert(Fs.remove_tree(root))
    return
  end
  assert(Fs.write(root .. "/a.tl", text({ "-- TODO: see `x`" })))
  assert(git_in(root, { "add", "." }))
  assert(git_in(root, { "commit", "-q", "-m", "one" }))
  assert(Fs.write(root .. "/a.tl", text({ "-- TODO: see [`x`]" })))
  assert(git_in(root, { "commit", "-q", "-am", "sweep" }))
  local handle = assert(work.open(root))
  local function listed(): {todos.Todo}
    assert(work.stage(handle, false))
    return assert(todos.list(handle.db, root)).todos
  end
  local all = listed()
  assert(all[1].summary == "sweep", all[1].summary)
  assert(todos.render(all[1]):find("see `x`$") ~= nil, todos.render(all[1]))
  local head = assert(Child.run({ assert(Proc.find("git")), "-C", root, "rev-parse", "HEAD" },
    { stdin = "null", stdout = "capture", stderr = "null" }))
  assert(Fs.write(root .. "/.git-blame-ignore-revs", head.stdout))
  assert(git_in(root, { "add", ".git-blame-ignore-revs" }))
  assert(git_in(root, { "commit", "-q", "-m", "ignore the sweep" }))
  all = listed()
  assert(all[1].summary == "one", all[1].summary)
  assert(work.close(handle))
  assert(Fs.remove_tree(root))
end

--- Lists the tree at `dir` once, staged first, and closes it.
local function list_once(dir: string): todos.Listing
  local handle = assert(work.open(dir))
  assert(work.stage(handle, false))
  local listing = assert(todos.list(handle.db, dir))
  assert(work.close(handle))
  return listing
end

--- A tree is blamed from the repository it sits in, as git finds one:
--- a `.git` above the tree, not in it, and a worktree's checkout, whose
--- `.git` is a file.
local function test_a_tree_in_a_repository_below_its_root_or_in_a_worktree_is_blamed(tmp: string)
  local root = tmp .. "/repository"
  assert(Fs.mkdirs(root .. "/sub"))
  if not git_in(root, { "init", "-q" }) then return end
  assert(Fs.write(root .. "/sub/a.tl", text({ "-- TODO: below the root" })))
  assert(git_in(root, { "add", "." }))
  assert(git_in(root, { "commit", "-q", "-m", "one" }))
  local below = list_once(root .. "/sub")
  assert(below.blamed == 1, "blamed " .. below.blamed)
  assert(#below.todos == 1 and below.todos[1].summary == "one", below.todos[1].summary)

  local checkout = tmp .. "/worktree"
  assert(git_in(root, { "worktree", "add", "-q", checkout }))
  assert(assert(Fs.stat(checkout .. "/.git")).kind == "file", "a worktree's .git is a file")
  local listing = list_once(checkout)
  assert(listing.blamed == 1, "blamed " .. listing.blamed)
  assert(#listing.todos == 1 and listing.todos[1].summary == "one", listing.todos[1].summary)
end
