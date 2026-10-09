--- `build.tree_root`: a tree verb started below an established tree's
--- root runs at the root, its paths read from where it was started.

local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local invoke = require("build.invoke")
local sys = require("cosmic.sys")
local tree_root = require("build.tree_root")
local build_paths = require("build.paths")

--- `root`'s build directory ([`build.paths`]), made, with `root` made
--- first where it is not there yet.
local function build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

--- The move a command line gets, or nil.
local function moved_by(argv: {integer:string}, options: {string:boolean | Flags.Option},
                        home: string | nil, named?: string): tree_root.Move | nil
  return tree_root.move(argv, options, home, named).move
end

--- A project in `dir` with a build's database, and a/b below it: its
--- path, resolved.
local function project(dir: string): string
  local tmp = assert(sys.realpath(dir))
  assert(build_dir(tmp .. "/proj"))
  assert(Fs.write(build_dir(tmp .. "/proj") .. "/cosmic.db", ""))
  assert(Fs.mkdirs(tmp .. "/proj/a/b"))
  -- What the last build staged: one source under a/b.
  local db = assert(Sqlite.open(build_dir(tmp .. "/proj") .. "/build.db", { writable = true }))
  assert(Sqlite.run(db, "CREATE TABLE files (path TEXT PRIMARY KEY, size INTEGER, " ..
      "mtime_ns INTEGER, ino INTEGER, dev INTEGER, sha256 TEXT, data BLOB) WITHOUT ROWID"))
  assert(Sqlite.run(db, "INSERT INTO files (path) VALUES ('a/b/x_test.tl')"))
  assert(db:close())
  return tmp .. "/proj"
end

--- The root `cosmic todos` would run at from `dir`, or nil where it runs
--- in `dir` itself.
local function rooted(dir: string, home: string | nil, named?: string): string | nil
  local here = assert(sys.getcwd())
  assert(sys.chdir(dir))
  local moved = moved_by({ [0] = "cosmic", "todos" }, {}, home, named)
  assert(sys.chdir(here))
  if moved == nil then return nil end
  return moved.root
end

--- The nearest ancestor a build established is the tree; the directory
--- holding the database is its own.
local function test_an_ancestor_with_a_built_database_is_the_tree(tmp: string)
  local root = project(tmp)
  assert(rooted(root .. "/a/b", nil) == root)
  assert(rooted(root .. "/a", nil) == root)
  assert(rooted(root, nil) == nil)
end

--- `o/build.db` alone is what a failed run leaves anywhere, so it makes
--- no directory a tree; a directory that holds a built database is its
--- own tree, nested or not.
local function test_only_a_built_database_establishes_a_tree(tmp: string)
  local root = project(tmp)
  assert(build_dir(root .. "/a"))
  assert(Fs.write(build_dir(root .. "/a") .. "/build.db", ""))
  assert(rooted(root .. "/a", nil) == root)
  assert(Fs.write(build_dir(root .. "/a") .. "/cosmic.db", ""))
  assert(rooted(root .. "/a", nil) == nil)
  -- The nearest built ancestor is a/, which staged nothing under a/b.
  assert(rooted(root .. "/a/b", nil) == nil)
end

--- A project made below a built tree, which that build never staged,
--- is a root of its own; one whose sources the build did stage is not.
local function test_a_new_project_in_a_built_tree_is_its_own_root(tmp: string)
  local root = project(tmp)
  assert(Fs.mkdirs(root .. "/fresh/greet"))
  assert(Fs.write(root .. "/fresh/greet/init.tl", "return {}\n"))
  assert(rooted(root .. "/fresh", nil) == nil)
  assert(rooted(root .. "/fresh/greet", nil) == nil)
  assert(rooted(root .. "/a/b", nil) == root)
  -- a/bc is not under a/b.
  assert(Fs.mkdirs(root .. "/a/bc"))
  assert(rooted(root .. "/a/bc", nil) == nil)
end

--- `COSMIC_TREE` names the root outright, `.` being where it started.
local function test_a_named_tree_is_the_root(tmp: string)
  local root = project(tmp)
  assert(Fs.mkdirs(root .. "/fresh"))
  assert(rooted(root .. "/fresh", nil, "..") == root)
  assert(rooted(root .. "/fresh", nil, root) == root)
  assert(rooted(root .. "/a/b", nil, ".") == nil)
end

--- No ancestor built, no move; and the home directory is not a tree
--- however it came by a database.
local function test_the_climb_stops_at_home_and_at_nothing_built(tmp: string)
  assert(Fs.mkdirs(tmp .. "/x/y"))
  assert(rooted(tmp .. "/x/y", nil) == nil)
  local root = project(tmp)
  assert(rooted(root .. "/a/b", root) == nil)
  assert(rooted(root .. "/a/b", nil) == root)
end

--- A path a verb names is read from where it was started, and the
--- options' values and module names are left as they are.
local function test_paths_are_read_from_where_the_verb_started(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/a/b/x_test.tl", ""))
  local here = assert(sys.getcwd())
  assert(sys.chdir(root .. "/a/b"))
  local fix = moved_by({ [0] = "cosmic", "fix", "--check", "x_test.tl", "." }, { ["--check"] = {} }, nil)
  local test = moved_by({ [0] = "cosmic", "test", "--jobs", "2", "x_test.tl:test_a", "some.module" },
    { ["--jobs"] = { value = "n" } }, nil)
  local uses = moved_by({ [0] = "cosmic", "uses", "Fs.read", "x_test.tl" }, {}, nil)
  local docs = moved_by({ [0] = "cosmic", "docs", "x_test.tl" }, {}, nil)
  local made = moved_by({ [0] = "cosmic", "fix", "new/x.tl", "../x.tl", "/elsewhere/y" }, {}, nil, nil)
  local json = moved_by({ [0] = "cosmic", "json", "x" }, {}, nil)
  assert(sys.chdir(here))
  assert(made ~= nil)
  assert(table.concat(made.argv, " ") == "fix a/b/new/x.tl a/x.tl /elsewhere/y",
    table.concat(made.argv, " "))
  assert(fix ~= nil and fix.root == root)
  assert(table.concat(fix.argv, " ") == "fix --check a/b/x_test.tl a/b", table.concat(fix.argv, " "))
  assert(test ~= nil)
  assert(table.concat(test.argv, " ") == "test --jobs 2 a/b/x_test.tl:test_a some.module",
    table.concat(test.argv, " "))
  assert(uses ~= nil and table.concat(uses.argv, " ") == "uses Fs.read a/b/x_test.tl")
  assert(docs ~= nil and docs.root == root and table.concat(docs.argv, " ") == "docs x_test.tl")
  assert(json == nil)
end

--- A verb started in a subdirectory answers for the tree, says which
--- root it used on stderr, and reads a path from the subdirectory.
local function test_a_verb_below_the_root_runs_at_the_root(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/a/b/note.tl", "-- TODO: once the root is found\nreturn 1\n"))
  local result = invoke.run({ "todos", "note.tl" }, { cwd = root .. "/a/b" })
  assert(result.code == 0, result.stderr .. result.stdout)
  assert(result.stderr:find("todos runs in " .. root, 1, true), result.stderr)
  assert(result.stdout:find("a/b/note.tl:1", 1, true), result.stdout)
  assert(not Fs.exists(build_paths.required(root .. "/a/b")))
end

--- The home directory stops the climb however it is spelled: with a
--- trailing slash, or through a link.
local function test_home_stops_the_climb_spelled_any_way(tmp: string)
  local root = project(tmp)
  assert(rooted(root .. "/a/b", root .. "/") == nil)
  assert(sys.symlink(root, tmp .. "/home"))
  assert(rooted(root .. "/a/b", tmp .. "/home") == nil)
end

--- A tree whose database cannot be read is not silently passed over:
--- the directory stays a root of its own, and the note says why.
local function test_an_unreadable_database_is_said(tmp: string)
  local root = project(tmp)
  assert(Fs.write(build_dir(root) .. "/build.db", "not a database"))
  local here = assert(sys.getcwd())
  assert(sys.chdir(root .. "/a/b"))
  local answer = tree_root.move({ [0] = "cosmic", "todos" }, {}, nil)
  assert(sys.chdir(here))
  assert(answer.move == nil and answer.refused == "")
  assert(answer.note:find("not using the tree at " .. root, 1, true), answer.note)
end

--- A root of `/` joins paths without a doubled slash.
local function test_a_root_of_slash_joins_cleanly(tmp: string)
  local root = project(tmp)
  local here = assert(sys.getcwd())
  assert(sys.chdir(root .. "/a"))
  local moved = moved_by({ [0] = "cosmic", "fix", "x.tl" }, {}, nil, "/")
  assert(sys.chdir(here))
  assert(moved ~= nil and moved.root == "/")
  assert(moved.argv[2] == root:sub(2) .. "/a/x.tl", moved.argv[2])
end

--- A `COSMIC_TREE` that names no directory refuses the command line, and
--- the verb does not run where it was started.
local function test_a_missing_named_tree_refuses_the_line(tmp: string)
  local root = project(tmp)
  local result = invoke.run({ "todos" }, { cwd = root .. "/a/b",
    env = { COSMIC_TREE = root .. "/nowhere" } })
  assert(result.code == 2, result.stderr)
  assert(result.stderr:find("COSMIC_TREE=" .. root .. "/nowhere is not a directory", 1, true),
    result.stderr)
  assert(not result.stderr:find("runs in", 1, true), result.stderr)
end
