#!/usr/bin/env cosmic
-- Tests for _make.refstamp: a declared git ref's commit, written to a
-- prerequisite so a moved ref is a moved dependency.
--
-- The properties that matter: an absent ref and a resolved one must
-- stamp differently, and so must two commits; the same commit twice
-- must stamp identically; write_all must resolve through git in the
-- project root, once per ref, and follow stamp.tl's write-if-changed
-- contract, so an unmoved ref never touches the mtime the graph
-- schedules on; and materialize must wire the stamp into deps_<stem>.

local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local graph = require("_make.graph")
local project = require("_make.project")
local refstamp = require("_make.refstamp")
local types = require("_make.types")

local type Project = types.Project

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Run one git command inside dir; any failure fails the test.
--- @return string Its stdout, trailing whitespace trimmed
local function git(dir: string, ...: string): string
  local argv: {string} = {"git", "-c", "user.name=t", "-c", "user.email=t@t"}
  local args = {...}
  for _, a in ipairs(args) do
    argv[#argv + 1] = a
  end
  local r = check.must(child.run(argv, {cwd = dir, stdin = ""}))
  assert(r.ok, "git " .. table.concat(args, " ") .. " failed: " .. r.stderr)
  return (r.stdout:gsub("%s+$", ""))
end

--- Build a fixture tree that is also a git repository with one commit
--- on the branch `scratch`, and scan it.
local function fixture(name: string, files: {string: string}): Project
  local root = fs.join(tmpdir, "refstamp-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.make_dirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  git(root, "init", "-q")
  git(root, "symbolic-ref", "HEAD", "refs/heads/scratch")
  git(root, "commit", "-q", "--allow-empty", "-m", "one")
  return check.must(project.scan(root))
end

--- Run fn with cwd inside dir, restoring it afterward.
local function in_dir<T>(dir: string, fn: function(): T): T
  local cwd = check.must(fs.cwd())
  assert(fs.set_cwd(dir))
  local got = fn()
  assert(fs.set_cwd(cwd))
  return got
end

-- Absent, one commit, another commit: three different stamps. A test
-- whose ref was fetched for the first time is as re-run-worthy as one
-- whose ref moved.
local function test_content_distinguishes_absent_and_each_commit()
  local absent = refstamp.content({"scratch"}, {})
  local one = refstamp.content({"scratch"}, {scratch = "aaaa"})
  local two = refstamp.content({"scratch"}, {scratch = "bbbb"})
  assert(absent ~= one, "absent and resolved must stamp differently")
  assert(one ~= two, "two commits must stamp differently")
  assert(absent ~= two, "absent and resolved must stamp differently")
end

-- Same names and commits, same bytes, whatever order the names came
-- in: content is a pure function of the declaration and the commits.
local function test_content_is_stable_and_sorted()
  local a = refstamp.content({"b", "a"}, {a = "1", b = "2"})
  local b = refstamp.content({"a", "b"}, {a = "1", b = "2"})
  assert(a == b, "identical inputs must stamp identically")
  assert(a == "a=1\nb=2\n", "got: " .. a)
end

-- An unresolved name stands bare, so a reader of the stamp sees which
-- ref was absent.
local function test_content_writes_an_absent_ref_bare()
  local got = refstamp.content({"origin/board"}, {})
  assert(got == "origin/board\n", "got: " .. got)
end

-- path_of: dot-prefixed under o/.ref/, so the mirror under o/ (which
-- maps o/<path> to the source at <path>) cannot collide with it.
local function test_path_of_is_dot_prefixed()
  local got = refstamp.path_of("_build/doc_paths_test")
  assert(got == "o/.ref/_build/doc_paths_test.ref", "got: " .. got)
end

local app = fixture("app", {
    ["cmd/app/main.tl"] = "print('x')\n",
    ["x_test.tl"] = "--- ref: scratch\nprint('ok')\n",
    ["y_test.tl"] = "print('ok')\n",
  })

-- resolve answers with the ref's commit, and with nil for a ref that
-- does not exist -- the "absent" the stamp writes bare.
local function test_resolve_answers_a_ref_and_not_a_missing_one()
  in_dir(app.root, function(): boolean
      local sha = git(app.root, "rev-parse", "scratch")
      assert(refstamp.resolve("scratch") == sha, "must resolve to " .. sha)
      assert(refstamp.resolve("no-such-ref") == nil, "a missing ref is nil")
      return true
    end)
end

-- write_all writes one stamp per declaring file, carrying the commit,
-- and nothing for a file with no declaration.
local function test_write_all_stamps_the_current_commit()
  in_dir(app.root, function(): boolean
      assert(check.must(refstamp.write_all(app)))
      local got = check.must(fs.read(refstamp.path_of("x_test")))
      local sha = git(app.root, "rev-parse", "scratch")
      assert(got == "scratch=" .. sha .. "\n", "got: " .. got)
      assert(not fs.is_file(refstamp.path_of("y_test")),
        "an undeclaring test must get no stamp")
      return true
    end)
end

-- Write-if-changed: a second write with the ref unmoved must not touch
-- the stamp's mtime, or every declaring test re-runs on every verb.
local function test_unmoved_ref_keeps_the_stamp_mtime()
  in_dir(app.root, function(): boolean
      assert(check.must(refstamp.write_all(app)))
      local probe = refstamp.path_of("x_test")
      assert(fs.set_times(probe, {atime = {secs = 0}, mtime = {secs = 0}}))
      assert(check.must(refstamp.write_all(app)))
      local sec = check.must(fs.stat(probe)):modify_time().secs
      assert(sec == 0, "an unmoved ref must not rewrite the stamp")
      return true
    end)
end

-- A moved ref DOES move the stamp -- the property the channel exists
-- for.
local function test_moved_ref_moves_the_stamp()
  in_dir(app.root, function(): boolean
      assert(check.must(refstamp.write_all(app)))
      local probe = refstamp.path_of("x_test")
      local before = check.must(fs.read(probe))
      git(app.root, "commit", "-q", "--allow-empty", "-m", "two")
      assert(check.must(refstamp.write_all(app)))
      local after = check.must(fs.read(probe))
      assert(before ~= after, "a moved ref must move the stamp")
      return true
    end)
end

-- materialize (graph.tl) wires the stamp into deps_<stem> and writes
-- it, beside the env stamp -- the integration this module feeds. An
-- undeclaring sibling gets no stamp in its closure.
local function test_materialize_carries_the_ref_stamp_in_deps()
  in_dir(app.root, function(): boolean
      assert(check.must(graph.materialize(app, "/bin/cosmic")))
      local mk = check.must(fs.read("o/project.mk"))
      assert(mk:find("deps_x_test := o/.ref/x_test.ref", 1, true),
        "the ref stamp must ride deps_x_test:\n" .. mk)
      local ydeps = mk:match("deps_y_test := ([^\n]*)")
      assert(ydeps and not ydeps:find("o/.ref/", 1, true),
        "an undeclaring sibling must not get a ref stamp:\n" .. mk)
      assert(fs.is_file("o/.ref/x_test.ref"),
        "materialize must have written the stamp file")
      return true
    end)
end

print("all refstamp tests passed")
