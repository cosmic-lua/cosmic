local positions = require("build.positions")

--- A module record for [`positions.check`]: `file` decides its path and
--- kind the way the importer's `inputs` view does, and `requires` is
--- what it imports.
local function module_at(file: string, requires: {string}, source: string): positions.Module
  local base = file:gsub("/init%.tl$", ""):gsub("%.tl$", "")
  return {
    path = (base:gsub("/", ".")),
    file = file,
    kind = if file:match("_test%.tl$") then "test" elseif
      file:match("_example%.tl$") then "example" elseif
      file:match("^cmd/[^/]+/main%.tl$") then "main" else "module" end,
    source = source, source_hash = "", requires = requires, tests = {},
    has_top_level_return = true, generated = false, key = "", lua = "",
  }
end

--- [`positions.check`] over `files` (each file and what it requires), in a
--- project tree or in cosmic's own.
local function positioned(files: {{string}}, own_tree: boolean,
                          carried?: function(name: string): boolean, sources?: {string: string}): boolean, string
  local modules: mut {positions.Module} = {}
  for _, row in ipairs(files) do
    local requires: mut {string} = {}
    for i = 2, #row do requires[#requires + 1] = row[i] end
    local file = assert(row[1])
    local source = ""
    if sources ~= nil then source = sources[file] or "" end
    modules[#modules + 1] = module_at(file, requires, source)
  end
  return positions.check(modules, { own = own_tree }, carried)
end

--- A directory's own `init.tl` is the one path in from outside: a
--- sibling beside it is reachable only from inside the directory.
local function test_position_keeps_an_entrys_siblings_inside()
  local ok, trouble = positioned({
    { "lib/init.tl" }, { "lib/part.tl" }, { "main.tl", "lib.part" },
  }, false)
  assert(not ok and trouble:find("main.tl: lib.part is private to lib/", 1, true) ~= nil, trouble)
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
  assert(not ok and trouble:find("tool/coverage/ has no init.tl entry", 1, true) ~= nil, trouble)
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

--- A module that says `--- @public` is open to every importer, wherever it sits: the server is the one closed member of
--- the http directory a file outside it may import; its siblings stay private.
local function test_position_opens_a_module_that_says_it_is_public()
  local tagged: {string: string} = { ["cosmic/http/server.tl"] = "--- An HTTP server.\n--- @public\nlocal x = 1\n" }
  local ok, trouble = positioned({
    { "cosmic/http/init.tl" }, { "cosmic/http/server.tl" }, { "cosmic/http/wire.tl" },
    { "cosmic/web/init.tl", "cosmic.http.server" },
  }, true, nil, tagged)
  assert(ok, trouble)
  ok, trouble = positioned({
    { "cosmic/http/init.tl" }, { "cosmic/http/wire.tl" },
    { "cosmic/web/init.tl", "cosmic.http.wire" },
  }, true, nil, tagged)
  assert(not ok and trouble:find("cosmic.http.wire is private to cosmic/http/", 1, true) ~= nil, trouble)
  assert(trouble:find("`--- @public`", 1, true) ~= nil, "the refusal says how to open it: " .. trouble)
  -- Without the line the same require is refused; the line is the module's own, in any project, and CR LF counts.
  ok, trouble = positioned({
    { "cosmic/http/init.tl" }, { "cosmic/http/server.tl" }, { "cosmic/web/init.tl", "cosmic.http.server" },
  }, true)
  assert(not ok and trouble:find("cosmic.http.server is private to cosmic/http/", 1, true) ~= nil, trouble)
  for _, own in ipairs({ true, false }) do
    ok, trouble = positioned({
      { "lib/init.tl" }, { "lib/part.tl" }, { "main.tl", "lib.part" },
    }, own, nil, { ["lib/part.tl"] = "--- A part.\r\n--- @public\r\nlocal x = 1\r\n" })
    assert(ok, trouble)
    ok, trouble = positioned({
      { "lib/init.tl" }, { "lib/part.tl" }, { "main.tl", "lib.part" },
    }, own, nil, { ["lib/part.tl"] = "-- see --- @public for what it means\nlocal x = 1\n" })
    assert(not ok, "the line inside another line opens nothing")
    ok, trouble = positioned({
      { "lib/init.tl" }, { "lib/part.tl" }, { "main.tl", "lib.part" },
    }, own, nil, { ["lib/part.tl"] = "local x = [[\n--- @public\n]]\n" })
    assert(not ok, "the line in a string, after the doc block, opens nothing")
  end
end

--- A directory's own entry is a member of the directory around it: one
--- nested in a closed directory is reachable only from inside that one.
local function test_position_closes_an_entry_nested_in_a_closed_directory()
  local ok, trouble = positioned({
    { "lib/deep/inner/init.tl" }, { "main.tl", "lib.deep.inner" },
  }, false)
  assert(not ok and trouble:find("is private to lib/deep/", 1, true) ~= nil, trouble)
  ok, trouble = positioned({
    { "lib/deep/inner/init.tl" }, { "lib/deep/user.tl", "lib.deep.inner" },
  }, false)
  assert(ok, trouble)
end

--- In cosmic's own tree `build/` is private to the tool: the standard
--- library and its examples may not import it, while the binary (a main), tests
--- and test support may. A project's own `build/` is its own business.
local function test_position_keeps_build_private_in_cosmics_own_tree()
  local ok, trouble = positioned({
    { "build/clock.tl" }, { "cosmic/time.tl", "build.clock" },
  }, true)
  assert(not ok and trouble:find("cosmic/time.tl: build.clock is private to build/ in cosmic's own tree", 1, true) ~= nil,
    trouble)
  -- A file of `cmd/` that is no main is the library's like any other.
  ok, trouble = positioned({ { "build/clock.tl" }, { "cmd/cosmic/helper.tl", "build.clock" } }, true)
  assert(not ok and trouble:find("cmd/cosmic/helper.tl: build.clock is private to build/", 1, true) ~= nil, trouble)
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

--- In cosmic's own tree only a test or test support may import a test: the tool's identity leaves every test out, so it
--- must carry none, and a module it carries that required one would carry it. Test support is a file of the top-level
--- `test/` directory, which is no more the tool's. A project's own program may, since its binary is built from its
--- tree whole.
local function test_position_keeps_tests_to_tests_in_cosmics_own_tree()
  for _, importer in ipairs({ "cosmic/time.tl", "cosmic/time_example.tl", "build/clock.tl", "cmd/cosmic/main.tl" }) do
    local ok, trouble = positioned({
      { "cosmic/fixture_test.tl" }, { importer, "cosmic.fixture_test" },
    }, true)
    assert(not ok and trouble:find(importer .. ": cosmic.fixture_test is a test or test support", 1, true) ~= nil,
      importer .. ": " .. tostring(trouble))
  end
  local ok, trouble = positioned({
    { "cosmic/fixture_test.tl" }, { "cosmic/time_test.tl", "cosmic.fixture_test" },
    { "test/probe.tl", "cosmic.fixture_test" },
  }, true)
  assert(ok, trouble)
  -- Support is required by tests and by support, and by nothing else.
  ok, trouble = positioned({
    { "test/helper.tl" }, { "test/probe.tl", "test.helper" }, { "cosmic/time_test.tl", "test.helper" },
  }, true)
  assert(ok, trouble)
  ok, trouble = positioned({ { "test/helper.tl" }, { "lib/time.tl", "test.helper" } }, true)
  assert(not ok and trouble:find("lib/time.tl: test.helper is a test or test support", 1, true) ~= nil, trouble)
  ok, trouble = positioned({
    { "fixture_test.tl" }, { "shared_example.tl", "fixture_test" }, { "cmd/hello/main.tl", "fixture_test" },
    { "test/helper.tl" }, { "app.tl", "test.helper" },
  }, false)
  assert(ok, trouble)
end

--- A test has no more reach than any other file: one outside a closed
--- directory is refused its siblings too.
local function test_position_refuses_a_test_outside_a_closed_directory()
  local ok, trouble = positioned({
    { "lib/init.tl" }, { "lib/part.tl" }, { "main_test.tl", "lib.part" },
  }, false)
  assert(not ok and trouble:find("main_test.tl: lib.part is private to lib/", 1, true) ~= nil, trouble)
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
  assert(not ok and trouble:find("lib/fs.tl: app.part is private to app/", 1, true) ~= nil, trouble)
end

--- In cosmic's own tree `cosmic/internal/` is internal to the tree root, not to `cosmic/`: the library's implementation
--- includes the tool, its main and its tests, and so everything beside `cosmic/` that the root holds.
local function test_position_opens_cosmic_internal_to_the_whole_own_tree()
  local ok, trouble = positioned({
    { "cosmic/internal/shared.tl" },
    { "cosmic/net.tl", "cosmic.internal.shared" },
    { "build/user.tl", "cosmic.internal.shared" },
    { "cmd/tool/main.tl", "cosmic.internal.shared" },
    { "cosmic/internal/shared_test.tl", "cosmic.internal.shared" },
    { "lang/user.tl", "cosmic.internal.shared" },
    { "eval/user.tl", "cosmic.internal.shared" },
    { "core/user_test.tl", "cosmic.internal.shared" },
  }, true)
  assert(ok, trouble)
end

--- A project tree may not require a `cosmic.internal.*` name, whether its
--- own file or the library's: the rule is named in the refusal.
local function test_position_refuses_cosmic_internal_in_a_project_tree()
  local ok, trouble = positioned({
    { "cosmic/internal/shared.tl" }, { "cosmic/net.tl", "cosmic.internal.shared" },
  }, false)
  assert(not ok and trouble:find("cosmic/net.tl: cosmic.internal.shared is internal to " ..
      "cosmic's own tree", 1, true) ~= nil, trouble)
  -- A Teal module the binary carries is refused; a raw table, which it
  -- holds no row of, is the reserved namespace's to guard.
  local function carries(name: string): boolean return name == "cosmic.internal.wire" end
  ok, trouble = positioned({ { "app/main.tl", "cosmic.internal.wire" } }, false, carries)
  assert(not ok and trouble:find("a project may not require it", 1, true) ~= nil, trouble)
  ok, trouble = positioned({ { "app/main.tl", "cosmic.internal.json" } }, false, carries)
  assert(ok, trouble)
end

--- A module whose path has an `internal` directory component may be required only by modules under that component's
--- parent, in every project, as in Go: the refusal names the rule and the two ways out.
local function test_position_holds_an_internal_directory_to_the_modules_around_it()
  local ok, trouble = positioned({
    { "app/internal/store.tl" }, { "app/main.tl", "app.internal.store" }, { "app/cli/run.tl", "app.internal.store" },
  }, false)
  assert(ok, trouble)
  ok, trouble = positioned({ { "app/internal/store.tl" }, { "other/main.tl", "app.internal.store" } }, false)
  assert(not ok and trouble:find("other/main.tl: app.internal.store is internal to app/ (it sits in app/internal/); " ..
      "only a module under app/ may require it: move other/main.tl under app/, or app/internal/store.tl out of internal/",
    1, true) ~= nil, trouble)
  -- A top-level `internal/` is the project's own: every module of it.
  ok, trouble = positioned({ { "internal/store.tl" }, { "main.tl", "internal.store" }, { "lib/run.tl", "internal.store" } },
    false)
  assert(ok, trouble)
  -- The last `internal` scopes: a.internal.b.internal.c is internal to a/internal/b/.
  ok, trouble = positioned({ { "a/internal/b/internal/c.tl" }, { "a/internal/b/d.tl", "a.internal.b.internal.c" },
    { "a/e.tl", "a.internal.b.internal.c" } }, false)
  assert(not ok and trouble:find("a/e.tl: a.internal.b.internal.c is internal to a/internal/b/", 1, true) ~= nil, trouble)
  -- It stands in the place of the closed-directory rule for the module: its entry and a nested module alike.
  ok, trouble = positioned({ { "app/internal/init.tl" }, { "app/internal/deep/x.tl" }, { "app/main.tl", "app.internal",
    "app.internal.deep.x" } }, false)
  assert(ok, trouble)
  -- The internal package itself is internal to its parent: `a/internal/init.tl` is the module a.internal, which a
  -- module outside a/ may not require (on main the top-level directory `a/` was a namespace, and it could).
  ok, trouble = positioned({ { "a/internal/init.tl" }, { "a/main.tl", "a.internal" } }, false)
  assert(ok, trouble)
  ok, trouble = positioned({ { "a/internal/init.tl" }, { "other/main.tl", "a.internal" } }, false)
  assert(not ok and trouble:find("other/main.tl: a.internal is internal to a/ (it sits in a/internal/)", 1, true) ~= nil,
    trouble)
  -- A directory that only holds the word is no internal one.
  ok, trouble = positioned({ { "app/internals/store.tl" }, { "other/main.tl", "app.internals.store" } }, true)
  assert(not ok and trouble:find("is private to app/internals/", 1, true) ~= nil, "a different name keeps the ordinary rule: " .. tostring(trouble))
  ok, trouble = positioned({ { "app/internal.tl" }, { "other/main.tl", "app.internal" } }, false)
  assert(ok, trouble)
end

--- The two exceptions hold in cosmic's own tree alone. A project's `cosmic/internal/` is refused whole (the reserved
--- namespace), and its `build/` is its own: neither takes the exception the library's does.
local function test_position_keeps_the_two_exceptions_to_cosmics_own_tree()
  local ok, trouble = positioned({ { "lang/x/internal/y.tl" }, { "eval/z.tl", "lang.x.internal.y" } }, true)
  assert(not ok and trouble:find("is internal to lang/x/", 1, true) ~= nil, trouble)
  ok, trouble = positioned({ { "cosmic/internal/s.tl" }, { "lang/user.tl", "cosmic.internal.s" } }, false)
  assert(not ok and trouble:find("cosmic.internal.s is internal to cosmic's own tree", 1, true) ~= nil, trouble)
  ok, trouble = positioned({ { "build/clock.tl" }, { "lib/time.tl", "build.clock" } }, false)
  assert(ok, trouble)
  ok, trouble = positioned({ { "build/clock.tl" }, { "lib/time.tl", "build.clock" } }, true)
  assert(not ok, "in the tree itself the directory is the tool's")
end
