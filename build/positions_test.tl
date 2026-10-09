local positions = require("build.positions")

--- A module record for [`positions.check`]: `file` decides its path and
--- kind the way the importer's `inputs` view does, and `requires` is
--- what it imports.
local function module_at(file: string, requires: {string}): positions.Module
  local base = file:gsub("/init%.tl$", ""):gsub("%.tl$", "")
  return {
    path = (base:gsub("/", ".")),
    file = file,
    kind = file:match("_test%.tl$") and "test" or
      file:match("_example%.tl$") and "example" or "module",
    source = "", source_hash = "", requires = requires, tests = {},
    has_top_level_return = true, generated = false, key = "", lua = "",
  }
end

--- [`positions.check`] over `files` (each file and what it requires), in a
--- project tree or in cosmic's own.
local function positioned(files: {{string}}, own_tree: boolean,
                          carried?: function(name: string): boolean): boolean, string
  local modules: {positions.Module} = {}
  for _, row in ipairs(files) do
    local requires: {string} = {}
    for i = 2, #row do requires[#requires + 1] = row[i] end
    modules[#modules + 1] = module_at(row[1], requires)
  end
  return positions.check(modules, own_tree, carried)
end

--- A directory's own `init.tl` is the one path in from outside: a
--- sibling beside it is reachable only from inside the directory.
local function test_position_keeps_an_entrys_siblings_inside()
  local ok, trouble = positioned({
    { "lib/init.tl" }, { "lib/part.tl" }, { "main.tl", "lib.part" },
  }, false)
  assert(not ok and trouble:find("main.tl: lib.part is private to lib/", 1, true), trouble)
  ok, trouble = positioned({
    { "lib/init.tl", "lib.part" }, { "lib/part.tl" }, { "main.tl", "lib" },
  }, false)
  assert(ok, trouble)
end

--- A nested directory with no `init.tl` has no entry, so nothing in it
--- is reachable from outside it -- not even when it holds one module --
--- while a file inside it still reaches its siblings.
local function test_position_closes_a_nested_directory_without_an_entry()
  local ok, trouble = positioned({
    { "tool/coverage/lines.tl" }, { "tool/test.tl", "tool.coverage.lines" },
  }, false)
  assert(not ok and trouble:find("tool/coverage/ has no init.tl entry", 1, true), trouble)
  ok, trouble = positioned({
    { "tool/coverage/lines.tl" },
    { "tool/coverage/report.tl", "tool.coverage.lines" },
    { "tool/coverage/lines_test.tl", "tool.coverage.lines" },
  }, false)
  assert(ok, trouble)
end

--- A top-level directory with no `init.tl` is a namespace of flat
--- modules, each public, the way [`cosmic/fs.tl`] is [`cosmic.fs`]; so is
--- the entry of a directory inside one.
local function test_position_opens_a_top_level_namespace()
  local ok, trouble = positioned({
    { "lib/fs.tl" }, { "lib/walk/init.tl" }, { "main.tl", "lib.fs", "lib.walk" },
    { "cmd/tool/main.tl", "lib.fs" },
  }, false)
  assert(ok, trouble)
end

--- A directory's own entry is a member of the directory around it: one
--- nested in a closed directory is reachable only from inside that one.
local function test_position_closes_an_entry_nested_in_a_closed_directory()
  local ok, trouble = positioned({
    { "lib/deep/inner/init.tl" }, { "main.tl", "lib.deep.inner" },
  }, false)
  assert(not ok and trouble:find("is private to lib/deep/", 1, true), trouble)
  ok, trouble = positioned({
    { "lib/deep/inner/init.tl" }, { "lib/deep/user.tl", "lib.deep.inner" },
  }, false)
  assert(ok, trouble)
end

--- In cosmic's own tree `build/` is private to the tool: the standard
--- library and its examples may not import it, while the binary, tests
--- and test support may. A project's own `build/` is its own business.
local function test_position_keeps_build_private_in_cosmics_own_tree()
  local ok, trouble = positioned({
    { "build/clock.tl" }, { "cosmic/time.tl", "build.clock" },
  }, true)
  assert(not ok and trouble:find("cosmic/time.tl: build.clock is private to build/", 1, true),
    trouble)
  ok, trouble = positioned({
    { "build/clock.tl" }, { "cosmic/time_example.tl", "build.clock" },
  }, true)
  assert(not ok, "an example may not import build/")
  ok, trouble = positioned({
    { "build/clock.tl" }, { "build/test.tl", "build.clock" },
    { "cmd/cosmic/main.tl", "build.clock" }, { "cosmic/time_test.tl", "build.clock" },
    { "test/portable/tool.tl", "build.clock" },
  }, true)
  assert(ok, trouble)
  ok, trouble = positioned({
    { "build/clock.tl" }, { "lib/time.tl", "build.clock" },
  }, false)
  assert(ok, trouble)
end

--- In cosmic's own tree only a test may import a test: the tool's
--- identity leaves every test out, so it must carry none, and a module
--- it carries that required one would carry it. A project's own
--- program may, since its binary is built from its tree whole.
local function test_position_keeps_tests_to_tests_in_cosmics_own_tree()
  for _, importer in ipairs({ "cosmic/time.tl", "cosmic/time_example.tl",
      "build/clock.tl", "cmd/cosmic/main.tl" }) do
    local ok, trouble = positioned({
      { "cosmic/fixture_test.tl" }, { importer, "cosmic.fixture_test" },
    }, true)
    assert(not ok and trouble:find(importer .. ": cosmic.fixture_test is a test", 1, true),
      importer .. ": " .. tostring(trouble))
  end
  local ok, trouble = positioned({
    { "cosmic/fixture_test.tl" }, { "cosmic/time_test.tl", "cosmic.fixture_test" },
  }, true)
  assert(ok, trouble)
  ok, trouble = positioned({
    { "fixture_test.tl" }, { "shared_example.tl", "fixture_test" },
    { "cmd/hello/main.tl", "fixture_test" },
  }, false)
  assert(ok, trouble)
end

--- A test has no more reach than any other file: one outside a closed
--- directory is refused its siblings too.
local function test_position_refuses_a_test_outside_a_closed_directory()
  local ok, trouble = positioned({
    { "lib/init.tl" }, { "lib/part.tl" }, { "main_test.tl", "lib.part" },
  }, false)
  assert(not ok and trouble:find("main_test.tl: lib.part is private to lib/", 1, true), trouble)
  ok, trouble = positioned({
    { "lib/init.tl" }, { "lib/part.tl" }, { "lib/part_test.tl", "lib.part" },
  }, false)
  assert(ok, trouble)
end

--- An `init.tl` at the root is the module `init`, a flat file of the
--- root like any other: public, and it closes nothing.
local function test_position_treats_a_root_init_as_a_flat_module()
  local ok, trouble = positioned({
    { "init.tl", "notes" }, { "notes.tl" }, { "lib/fs.tl", "init" },
  }, false)
  assert(ok, trouble)
end

--- A top-level directory with its own `init.tl` is closed, yet its files
--- may import from a top-level namespace beside it, which is open.
local function test_position_lets_a_closed_directory_import_an_open_namespace()
  local ok, trouble = positioned({
    { "app/init.tl", "app.part", "lib.fs" }, { "app/part.tl", "lib.fs" },
    { "lib/fs.tl" },
  }, false)
  assert(ok, trouble)
  ok, trouble = positioned({
    { "app/init.tl" }, { "app/part.tl" }, { "lib/fs.tl", "app.part" },
  }, false)
  assert(not ok and trouble:find("lib/fs.tl: app.part is private to app/", 1, true), trouble)
end

--- A Teal module directly in `cosmic/internal/` is shared machinery: the
--- tree's own `cosmic/`, `build/`, `cmd/` and tests import it, though
--- its home has a slash, and anything else in cosmic's own tree does not.
local function test_position_opens_cosmic_internal_to_the_trees_own_modules()
  local ok, trouble = positioned({
    { "cosmic/internal/shared.tl" },
    { "cosmic/net.tl", "cosmic.internal.shared" },
    { "build/user.tl", "cosmic.internal.shared" },
    { "cmd/tool/main.tl", "cosmic.internal.shared" },
    { "cosmic/internal/shared_test.tl", "cosmic.internal.shared" },
    { "ci/user_test.tl", "cosmic.internal.shared" },
  }, true)
  assert(ok, trouble)
  ok, trouble = positioned({
    { "cosmic/internal/shared.tl" }, { "ci/user.tl", "cosmic.internal.shared" },
  }, true)
  assert(not ok and trouble:find("ci/user.tl: cosmic.internal.shared is internal to cosmic",
    1, true), trouble)
end

--- A project tree may not require a `cosmic.internal.*` name, whether its
--- own file or the library's: the rule is named in the refusal.
local function test_position_refuses_cosmic_internal_in_a_project_tree()
  local ok, trouble = positioned({
    { "cosmic/internal/shared.tl" }, { "cosmic/net.tl", "cosmic.internal.shared" },
  }, false)
  assert(not ok and trouble:find("cosmic/net.tl: cosmic.internal.shared is internal to " ..
      "cosmic's own tree", 1, true), trouble)
  -- A Teal module the binary carries is refused; a raw table, which it
  -- holds no row of, is the reserved namespace's to guard.
  local function carries(name: string): boolean return name == "cosmic.internal.wire" end
  ok, trouble = positioned({ { "app/main.tl", "cosmic.internal.wire" } }, false, carries)
  assert(not ok and trouble:find("a project may not require it", 1, true), trouble)
  ok, trouble = positioned({ { "app/main.tl", "cosmic.internal.json" } }, false, carries)
  assert(ok, trouble)
end
