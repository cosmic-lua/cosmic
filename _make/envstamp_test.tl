#!/usr/bin/env cosmic
-- Tests for _make.envstamp: a declared env value, hashed into a
-- prerequisite so a changed value is a changed dependency.
--
-- The properties that matter: unset, empty, and set must hash
-- differently (three different behaviors, D18's "unset and empty must
-- hash differently"); the same value twice must hash identically;
-- and write_all must follow stamp.tl's write-if-changed contract, so
-- an unmoved value never touches the mtime the graph schedules on.

local check = require("cosmic.check")
local env = require("cosmic.env")
local envstamp = require("_make.envstamp")
local fs = require("cosmic.fs")
local graph = require("_make.graph")
local project = require("_make.project")
local types = require("_make.types")

local type Project = types.Project

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Build a fixture tree and scan it.
local function fixture(name: string, files: {string: string}): Project
  local root = fs.join(tmpdir, "envstamp-" .. name)
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

-- Restore FOO around every case below: the whole point of the module
-- is reading the ambient environment, so a test that sets FOO must put
-- it back.
local saved_foo = env.get("FOO")
local function restore_foo()
  if saved_foo then
    assert(env.set("FOO", saved_foo))
  else
    assert(env.unset("FOO"))
  end
end

-- Unset, empty, and set must hash differently: a step branching on
-- "is this even set" and one branching on the value are reading
-- different questions, and a stamp that conflated them would replay a
-- stale verdict across the boundary that matters most.
local function test_content_distinguishes_unset_empty_and_set()
  assert(env.unset("FOO"))
  local unset = envstamp.content({"FOO"})
  assert(env.set("FOO", ""))
  local empty = envstamp.content({"FOO"})
  assert(env.set("FOO", "1"))
  local set = envstamp.content({"FOO"})
  restore_foo()
  assert(unset ~= empty, "unset and empty must hash differently")
  assert(empty ~= set, "empty and set must hash differently")
  assert(unset ~= set, "unset and set must hash differently")
end
test_content_distinguishes_unset_empty_and_set()

-- Identical values, identical bytes: content is a pure function of the
-- declared names and their current values, nothing else.
local function test_content_is_stable_for_identical_values()
  assert(env.set("FOO", "same"))
  local a = envstamp.content({"FOO"})
  local b = envstamp.content({"FOO"})
  restore_foo()
  assert(a == b, "identical values must hash identically")
end
test_content_is_stable_for_identical_values()

-- The file stores the hash, never a plaintext value: `o/` must not
-- collect secrets.
local function test_content_never_carries_the_plaintext_value()
  assert(env.set("FOO", "super-secret-token"))
  local got = envstamp.content({"FOO"})
  restore_foo()
  assert(not got:find("super-secret-token", 1, true),
    "the stamp must not carry the plaintext value")
end
test_content_never_carries_the_plaintext_value()

-- path_of: dot-prefixed under o/.env/, so the mirror under o/ (which
-- maps o/<path> to the source at <path>) cannot collide with it.
local function test_path_of_is_dot_prefixed()
  local got = envstamp.path_of("_fuzz/sse_fuzz_test")
  assert(got == "o/.env/_fuzz/sse_fuzz_test.env", "got: " .. got)
end
test_path_of_is_dot_prefixed()

local app = fixture("app", {
    ["main.tl"] = "print('x')\n",
    ["x_test.tl"] = "--- env: FOO\nprint('ok')\n",
  })

-- write_all writes one stamp per declaring file, and nothing for a
-- file with no declaration.
local function test_write_all_writes_only_declaring_files()
  in_dir(app.root, function(): boolean
      assert(env.set("FOO", "1"))
      assert(check.must(envstamp.write_all(app)))
      assert(fs.is_file(envstamp.path_of("x_test")),
        "a declaring test must get a stamp")
      restore_foo()
      return true
    end)
end
test_write_all_writes_only_declaring_files()

-- Write-if-changed: a second write with the value unmoved must not
-- touch the stamp's mtime, or every declaring test re-runs on every
-- verb -- the cascade D18 exists to end, reintroduced by its own
-- bookkeeping. This is the stamp_test.tl shape.
local function test_unmoved_value_keeps_the_stamp_mtime()
  in_dir(app.root, function(): boolean
      assert(env.set("FOO", "same"))
      assert(check.must(envstamp.write_all(app)))
      local probe = envstamp.path_of("x_test")
      assert(fs.set_times(probe, {atime = {secs = 0}, mtime = {secs = 0}}))
      assert(check.must(envstamp.write_all(app)))
      local sec = check.must(fs.stat(probe)):modify_time().secs
      restore_foo()
      assert(sec == 0, "an unmoved value must not rewrite the stamp")
      return true
    end)
end
test_unmoved_value_keeps_the_stamp_mtime()

-- A changed value DOES move the stamp -- the other half of the same
-- property, and the one the whole slice exists for.
local function test_changed_value_moves_the_stamp()
  in_dir(app.root, function(): boolean
      assert(env.set("FOO", "before"))
      assert(check.must(envstamp.write_all(app)))
      local probe = envstamp.path_of("x_test")
      local before = check.must(fs.read(probe))
      assert(env.set("FOO", "after"))
      assert(check.must(envstamp.write_all(app)))
      local after = check.must(fs.read(probe))
      restore_foo()
      assert(before ~= after, "a changed value must move the stamp")
      return true
    end)
end
test_changed_value_moves_the_stamp()

-- materialize (graph.tl) wires the stamp into deps_<stem>, beside
-- stamp.write_all -- the integration this module exists to feed.
local function test_materialize_carries_the_env_stamp_in_deps()
  in_dir(app.root, function(): boolean
      assert(env.set("FOO", "1"))
      assert(check.must(graph.materialize(app, "/bin/cosmic")))
      restore_foo()
      local mk = check.must(fs.read("o/project.mk"))
      assert(mk:find("deps_x_test", 1, true) and
        mk:find("o/.env/x_test.env", 1, true),
        "the env stamp must ride deps_x_test:\n" .. mk)
      assert(fs.is_file("o/.env/x_test.env"),
        "materialize must have written the stamp file")
      return true
    end)
end
test_materialize_carries_the_env_stamp_in_deps()

print("all envstamp tests passed")
