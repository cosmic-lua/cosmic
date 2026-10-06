--- `cosmic todos` over a repository's history: blame recorded at one
--- `HEAD` carries on to the next for every file the commits between them
--- leave alone. git's answers are recorded in testdata/todos_git
--- (testdata/todos_git/record.sh makes them again from the system's git),
--- and the test hands [`todos.list`] a stand-in that replays them, so none
--- starts a process. build/todos_live_git_test.tl runs the system's git
--- itself, once, for what a recording cannot say: that git takes the
--- arguments the verb gives it.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local todos = require("build.todos")
local work = require("build.work")

Test.policy{ grants = { { path = "testdata/todos_git", letters = "r" } } }

local DATA <const> = "testdata/todos_git"

--- Lines joined into one file's text, so no line of this file opens
--- with a comment marker and is listed itself.
local function text(lines: {string}): string
  return table.concat(lines, "\n") .. "\n"
end

--- Which recorded step of a scenario the repository stands at, and
--- whether `.git-blame-ignore-revs` is there for blame to name.
local record Replay
  scenario: string
  step: string
  ignored: boolean
end

--- A recorded file of the replay's step.
local function recorded(replay: Replay, name: string): string | nil
  local data, _ = Fs.read(DATA .. "/" .. replay.scenario .. "/" .. replay.step .. "/" .. name)
  return data
end

--- git's answer to one call in `root`, from what was recorded at the
--- replay's step: a call the recording holds no answer to, or one in
--- another shape than the verb's, fails the test, where git would
--- have said something the test cannot know.
local function answer(replay: Replay, root: string, args: {string}): string | nil
  local said = table.concat(args, " ")
  local head = assert(recorded(replay, "head"), "no head recorded: " .. said)
  local verb = args[1]
  if verb == "rev-parse" then
    assert(said == "rev-parse --verify -q HEAD", said)
    return head
  elseif verb == "merge-base" then
    assert(#args == 4 and args[2] == "--is-ancestor" and args[4] .. "\n" == head, said)
    local ancestors = assert(recorded(replay, "ancestors"))
    return ("\n" .. ancestors):find("\n" .. args[3] .. "\n", 1, true) and "" or nil
  elseif verb == "diff" then
    assert(#args == 7 and table.concat(args, " ", 1, 4) == "diff --name-only --no-renames --relative" and
        args[6] .. "\n" == head and args[7] == "--", said)
    return (assert(recorded(replay, "diff-" .. args[5]), "no diff recorded: " .. said))
  elseif verb == "blame" then
    local at = 3
    assert(args[2] == "--line-porcelain", said)
    if replay.ignored then
      assert(args[3] == "--ignore-revs-file" and args[4] == root .. "/.git-blame-ignore-revs", said)
      at = 5
    end
    assert(#args == at + 3 and args[at] == "-L" and args[at + 1] == "1,1" and args[at + 2] == "--", said)
    return (assert(recorded(replay, args[at + 3]:gsub("/", "_") .. ".blame"), "no blame recorded: " .. said))
  end
  error("unexpected git call: " .. said)
end

--- A repository's marker in `root`, which is all the verb looks for
--- before it asks git, and a replay of `scenario` to ask.
local function replaying(root: string, scenario: string): Replay, function(string, {string}): string | nil
  assert(Fs.mkdirs(root .. "/.git"))
  local replay: Replay = { scenario = scenario, step = "1", ignored = false }
  return replay, function(at: string, args: {string}): string | nil
    return answer(replay, at, args)
  end
end

local function test_blame_carries_across_commits_that_leave_a_file_alone()
  local root = assert(Fs.mkdtemp("cosmic-todos-test-"))
  local replay, run_git = replaying(root, "carries")
  assert(Fs.write(root .. "/a.tl", text({ "-- TODO: first" })))
  assert(Fs.write(root .. "/b.tl", text({ "-- TODO: second" })))
  local handle = assert(work.open(root))
  local function listed(step: string): {todos.Todo}, integer
    replay.step = step
    assert(work.stage(handle, false))
    local listing = assert(todos.list(handle.db, root, run_git))
    return listing.todos, listing.blamed
  end
  local all, blamed = listed("1")
  assert(blamed == 2, "blamed " .. blamed)
  assert(all[1].commit ~= "" and all[1].summary == "one", all[1].summary)

  -- A commit that touches neither file blames neither again.
  assert(Fs.write(root .. "/c.tl", text({ "local c = 3" })))
  all, blamed = listed("2")
  assert(blamed == 0, "blamed " .. blamed)
  assert(all[2].summary == "one", all[2].summary)

  -- One that touches a file blames that file alone.
  assert(Fs.write(root .. "/b.tl", text({ "-- TODO: second, reworded" })))
  all, blamed = listed("3")
  assert(blamed == 1, "blamed " .. blamed)
  assert(all[1].summary == "one" and all[2].summary == "three", all[2].summary)

  -- A rewritten history may have dropped the commits a row names.
  all, blamed = listed("4")
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
  local replay, run_git = replaying(root, "ignores")
  assert(Fs.write(root .. "/a.tl", text({ "-- TODO: see [`x`]" })))
  local handle = assert(work.open(root))
  local function listed(): {todos.Todo}
    assert(work.stage(handle, false))
    return assert(todos.list(handle.db, root, run_git)).todos
  end
  local all = listed()
  assert(all[1].summary == "sweep", all[1].summary)
  assert(todos.render(all[1]):find("see `x`$") ~= nil, todos.render(all[1]))
  replay.step = "2"
  replay.ignored = true
  assert(Fs.write(root .. "/.git-blame-ignore-revs", assert(recorded({ scenario = "ignores", step = "1",
    ignored = false }, "head"))))
  all = listed()
  assert(all[1].summary == "one", all[1].summary)
  assert(work.close(handle))
  assert(Fs.remove_tree(root))
end

--- Lists the tree at `dir` once, staged first, and closes it.
local function list_once(dir: string, run_git: function(string, {string}): string | nil): todos.Listing
  local handle = assert(work.open(dir))
  assert(work.stage(handle, false))
  local listing = assert(todos.list(handle.db, dir, run_git))
  assert(work.close(handle))
  return listing
end

--- A tree is blamed from the repository it sits in, as the verb looks for
--- one: a `.git` above the tree, not in it, and a worktree's checkout,
--- whose `.git` is a file.
local function test_a_tree_in_a_repository_below_its_root_or_in_a_worktree_is_blamed(tmp: string)
  local root = tmp .. "/repository"
  assert(Fs.mkdirs(root .. "/sub"))
  local replay, run_git = replaying(root, "placed")
  replay.step = "below"
  assert(Fs.write(root .. "/sub/a.tl", text({ "-- TODO: below the root" })))
  local below = list_once(root .. "/sub", run_git)
  assert(below.blamed == 1, "blamed " .. below.blamed)
  assert(#below.todos == 1 and below.todos[1].summary == "one", below.todos[1].summary)

  local checkout = tmp .. "/worktree"
  assert(Fs.mkdirs(checkout .. "/sub"))
  assert(Fs.write(checkout .. "/.git", "gitdir: " .. root .. "/.git/worktrees/worktree\n"))
  assert(assert(Fs.stat(checkout .. "/.git")).kind == "file", "a worktree's .git is a file")
  assert(Fs.write(checkout .. "/sub/a.tl", text({ "-- TODO: below the root" })))
  replay.step = "worktree"
  local listing = list_once(checkout, run_git)
  assert(listing.blamed == 1, "blamed " .. listing.blamed)
  assert(#listing.todos == 1 and listing.todos[1].summary == "one", listing.todos[1].summary)
end
