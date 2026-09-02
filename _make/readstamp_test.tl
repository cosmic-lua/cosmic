#!/usr/bin/env cosmic
-- Tests for _make.readstamp: a declared `reads:` tree's LISTING,
-- hashed into a prerequisite so a rename, add, or delete inside it is
-- a changed dependency even when every file's own mtime survives the
-- edit untouched (mv/git mv both preserve it).

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local graph = require("_make.graph")
local project = require("_make.project")
local readstamp = require("_make.readstamp")
local types = require("_make.types")

local type Project = types.Project

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Build a fixture tree and scan it.
local function fixture(name: string, files: {string: string}): Project
  local root = fs.join(tmpdir, "readstamp-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.make_dirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  local proj = check.must(project.scan(root))
  return proj
end

--- Run fn with cwd inside dir, restoring it afterward.
local function in_dir<T>(dir: string, fn: function(): T): T
  local cwd = check.must(fs.cwd())
  assert(fs.set_cwd(dir))
  local got = fn()
  assert(fs.set_cwd(cwd))
  return got
end

-- Identical lists, identical bytes: content is a pure function of the
-- expanded paths, nothing else — order does not matter, `content`
-- sorts before hashing.
local function test_content_is_stable_regardless_of_order()
  local a = readstamp.content({"notes/a.md", "notes/b.md"})
  local b = readstamp.content({"notes/b.md", "notes/a.md"})
  assert(a == b, "the same set in a different order must hash identically")
end

-- The whole point: a different SET of names hashes differently, even
-- when the total count is unchanged — a rename swaps one name for
-- another without adding or removing a file.
local function test_a_renamed_member_changes_the_content()
  local before = readstamp.content({"notes/a.md"})
  local after = readstamp.content({"notes/b.md"})
  assert(before ~= after, "a renamed member must change the stamp's content")
end

-- path_of: dot-prefixed under o/.reads/, so the mirror under o/
-- (which maps o/<path> to the source at <path>) cannot collide with
-- it — same convention as envstamp's o/.env/.
local function test_path_of_is_dot_prefixed()
  local got = readstamp.path_of("_build/doc_paths_test")
  assert(got == "o/.reads/_build/doc_paths_test.reads", "got: " .. got)
end

local app = fixture("app", {
    ["main.tl"] = "print('x')\n",
    ["notes/a.md"] = "subject\n",
    ["x_test.tl"] = "--- reads: notes\nprint('ok')\n",
    ["y_test.tl"] = "print('ok')\n",
  })

-- write_all writes one stamp per file with a non-empty `reads:`
-- declaration, and nothing for an undeclared sibling.
local function test_write_all_writes_only_declaring_files()
  in_dir(app.root, function(): boolean
      assert(check.must(readstamp.write_all(app)))
      assert(fs.is_file(readstamp.path_of("x_test")),
        "a declaring test must get a stamp")
      assert(not fs.is_file(readstamp.path_of("y_test")),
        "an undeclared sibling must not get a stamp")
      return true
    end)
end

-- Write-if-changed: a second write over an unchanged tree must not
-- touch the stamp's mtime, or every declaring test re-runs on every
-- verb — the exact cascade D18 exists to end.
local function test_an_unchanged_listing_keeps_the_stamp_mtime()
  in_dir(app.root, function(): boolean
      assert(check.must(readstamp.write_all(app)))
      local probe = readstamp.path_of("x_test")
      assert(fs.set_times(probe, {atime = {secs = 0}, mtime = {secs = 0}}))
      assert(check.must(readstamp.write_all(app)))
      local sec = check.must(fs.stat(probe)):modify_time().secs
      assert(sec == 0, "an unchanged listing must not rewrite the stamp")
      return true
    end)
end

-- A rename inside the declared tree DOES move the stamp — the other
-- half of the same property, and the one this module exists for.
local function test_a_rename_inside_the_tree_moves_the_stamp()
  in_dir(app.root, function(): boolean
      assert(check.must(readstamp.write_all(app)))
      local probe = readstamp.path_of("x_test")
      local before = check.must(fs.read(probe))
      assert(fs.move(fs.join(app.root, "notes/a.md"),
          fs.join(app.root, "notes/b.md")))
      local renamed = check.must(project.scan(app.root))
      assert(check.must(readstamp.write_all(renamed)))
      local after = check.must(fs.read(probe))
      assert(before ~= after, "a rename inside the tree must move the stamp")
      return true
    end)
end

-- materialize (graph.tl) wires the stamp into deps_<stem>, beside
-- envstamp.write_all — the integration this module exists to feed.
local function test_materialize_carries_the_reads_stamp_in_deps()
  in_dir(app.root, function(): boolean
      assert(check.must(graph.materialize(app, "/bin/cosmic")))
      local mk = check.must(fs.read("o/project.mk"))
      assert(mk:find("deps_x_test", 1, true) and
        mk:find("o/.reads/x_test.reads", 1, true),
        "the reads stamp must ride deps_x_test:\n" .. mk)
      assert(fs.is_file("o/.reads/x_test.reads"),
        "materialize must have written the stamp file")
      return true
    end)
end

print("all readstamp tests passed")
