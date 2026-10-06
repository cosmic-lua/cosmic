--- `cosmic todos` over a git repository the system's git makes: that git
--- takes the arguments the verb gives it (blame past the commits the tree
--- ignores, `merge-base`, `diff`) and says what the verb reads. It starts
--- git, so it is a module of its own, which a host without one skips;
--- build/todos_git_test.tl runs the same cases against recorded answers,
--- and build/todos_test.tl's trees are in no repository and start none.

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
Test.policy{ profiles = { "system" }, env = { "PATH" }, requires = { "program:git" } }

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

--- One history through every call the verb makes: a first blame, a
--- commit that leaves the files alone, one that rewrites a line, an ignore
--- file that passes over it, and a tree below the repository's root.
local function test_the_systems_git_answers_what_the_verb_asks()
  local root = assert(Fs.mkdtemp("cosmic-todos-test-"))
  assert(git_in(root, { "init", "-q" }))
  assert(Fs.mkdirs(root .. "/sub"))
  assert(Fs.write(root .. "/a.tl", text({ "-- TODO: see `x`" })))
  assert(Fs.write(root .. "/sub/b.tl", text({ "-- TODO: below the root" })))
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
  assert(all[1].summary == "one" and all[2].summary == "one", all[1].summary)

  -- A commit that touches neither file blames neither again.
  assert(Fs.write(root .. "/c.tl", text({ "local c = 3" })))
  assert(git_in(root, { "add", "c.tl" }))
  assert(git_in(root, { "commit", "-q", "-m", "two" }))
  all, blamed = listed()
  assert(blamed == 0, "blamed " .. blamed)

  -- One that rewrites a line blames its file alone.
  assert(Fs.write(root .. "/a.tl", text({ "-- TODO: see [`x`]" })))
  assert(git_in(root, { "commit", "-q", "-am", "sweep" }))
  all, blamed = listed()
  assert(blamed == 1, "blamed " .. blamed)
  assert(all[1].summary == "sweep" and all[2].summary == "one", all[1].summary)
  assert(todos.render(all[1]):find("see `x`$") ~= nil, todos.render(all[1]))

  -- The commits the tree ignores are passed over.
  local head = assert(Child.run({ assert(Proc.find("git")), "-C", root, "rev-parse", "HEAD" },
    { stdin = "null", stdout = "capture", stderr = "null" }))
  assert(Fs.write(root .. "/.git-blame-ignore-revs", head.stdout))
  assert(git_in(root, { "add", ".git-blame-ignore-revs" }))
  assert(git_in(root, { "commit", "-q", "-m", "ignore the sweep" }))
  all = listed()
  assert(all[1].summary == "one", all[1].summary)

  -- A rewritten history may have dropped the commits a row names.
  assert(git_in(root, { "commit", "-q", "--amend", "-m", "ignore the sweep again" }))
  all, blamed = listed()
  assert(blamed == 2, "blamed " .. blamed)
  assert(work.close(handle))

  -- A tree below the repository's root is blamed from the repository.
  local below = assert(work.open(root .. "/sub"))
  assert(work.stage(below, false))
  local listing = assert(todos.list(below.db, root .. "/sub"))
  assert(work.close(below))
  assert(listing.blamed == 1 and listing.todos[1].summary == "one", listing.blamed)
  assert(Fs.remove_tree(root))
end
