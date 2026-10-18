local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local type Log = require("cosmic.log")
local paths = require("build.paths")
local reboot = require("build.reboot")
local rebuild = require("build.rebuild")
local rebuild_lock = require("build.rebuild_lock")
local stand_in = require("build.stand_in")
local logger = require("build.logger")
local work = require("build.work")

--- A core change boots unless COSMIC_AUTO_BOOT is "0".
local function test_auto_boot_unless_told_not_to()
  assert(reboot.auto_boot({}))
  assert(reboot.auto_boot({ COSMIC_AUTO_BOOT = "1" }))
  assert(not reboot.auto_boot({ COSMIC_AUTO_BOOT = "0" }))
end

--- A tree whose bin/zig is a stand-in that records how it was run and
--- exits with `status`.
local function tree_with_zig(tmp: string, status: integer): string
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/bin"))
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(stand_in.place(probe, root .. "/bin/zig",
    "write $DIR/ran $@\nprint built\nexit " .. tostring(status)))
  return root
end

--- What `run` answers, as text, and what the logger is given to
--- complain of while it runs, a line each.
local function complaints(run: function(): string): string, string
  local said: {string} = {}
  local log = logger.log
  local complain = log.complain
  log.complain = function(_: Log.Logger, line: string): boolean, string
    table.insert(said, line)
    return true, ""
  end
  local ran, answer = pcall(run)
  log.complain = complain
  assert(ran, tostring(answer))
  return tostring(answer), table.concat(said, "\n")
end

--- A boot that fails is reported, not re-entered.
local function test_boot_into_reports_a_failed_boot(tmp: string)
  local root = tree_with_zig(tmp, 1)
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" }, {})
  assert(trouble:find("bin/zig build boot failed", 1, true), trouble)
  assert(Fs.read(root .. "/bin/ran") == "build boot\n")
end

--- The boot a run holding the rebuild lock starts is handed that lock
--- (build/zig.tl takes it otherwise, and would wait on its parent for
--- good); one started by a run that holds none is handed nothing.
local function test_boot_into_hands_on_the_lock_it_holds(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root))
  local layout = paths.resolve(root)
  assert(Fs.mkdirs(root .. "/bin") and Fs.mkdirs(layout.directory))
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(stand_in.place(probe, root .. "/bin/zig",
    "write $DIR/handed [$COSMIC_REBUILD_LOCK_HANDED]\nexit 1"))
  local _ = reboot.boot_into(root, { [0] = "cosmic", "test" }, {})
  assert(Fs.read(root .. "/bin/handed") == "[]\n", Fs.read(root .. "/bin/handed"))
  assert(rebuild_lock.take(root, 0, "test") == "held")
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" }, {})
  rebuild_lock.release()
  assert(trouble:find("bin/zig build boot failed", 1, true), trouble)
  assert(Fs.read(root .. "/bin/handed") == "[" .. layout.lock .. "]\n",
    Fs.read(root .. "/bin/handed"))
end

--- After a boot, the tool it wrote is what runs the command again; one
--- that is not there is reported rather than silently skipped.
local function test_boot_into_enters_the_booted_tool(tmp: string)
  local root = tree_with_zig(tmp, 0)
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" }, {})
  assert(Fs.read(root .. "/bin/ran") == "build boot\n")
  assert(trouble ~= "", "boot_into returned without a reason")
end

--- A tool still stale after its own boot refuses instead of booting
--- again. Its bin/zig cannot start, so no stand-in need be built: a
--- boot would have been refused with another reason.
local function test_boot_into_boots_once(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/bin"))
  assert(Fs.write(root .. "/bin/zig", "#!/nonexistent/interpreter\n", 0x1ed))
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" },
    { COSMIC_REBOOTED = "1" })
  assert(trouble == "the tool is still stale after a reboot", trouble)
end

--- The tree's compiler has moved from the tool's when their identities
--- differ; an identity that could not be taken, on either side, is no
--- evidence of a move.
local function test_compiler_moved_compares_identities()
  assert(reboot.compiler_moved("old", "new"))
  assert(not reboot.compiler_moved("same", "same"))
  assert(not reboot.compiler_moved(nil, "new"))
  assert(not reboot.compiler_moved("old", nil))
  assert(not reboot.compiler_moved(nil, nil))
end

-- TODO: `into`'s second answer, its nil fallback for the tree's compiler
-- identity and `guard`'s passing it to `rebuild_failed` are untested here
-- (forcing `moved` to false would pass): add a ci/fixtures/self_rebuild_test.tl
-- case that stages a tree whose compiler module changed and whose rebuild
-- fails with the stale tool, asserting a boot is attempted, and exit 3 with
-- COSMIC_AUTO_BOOT=0.

--- A rebuild whose compile failed because the compiler moved boots, as a
--- core change does, and re-enters the tool the boot wrote.
local function test_rebuild_failed_boots_when_the_compiler_moved(tmp: string)
  local root = tree_with_zig(tmp, 1)
  local code = reboot.rebuild_failed(root, { [0] = "cosmic", "test" },
    "checker: T (unresolved generic)", true, {})
  assert(code == 3, code)
  assert(Fs.read(root .. "/bin/ran") == "build boot\n")
end

--- A boot that then fails says the compile failure it was to mend, which
--- would otherwise be lost to the boot's own trouble.
local function test_rebuild_failed_says_the_compile_failure_of_a_failed_boot(tmp: string)
  local root = tree_with_zig(tmp, 1)
  local code, all = complaints(function(): string
    return tostring(reboot.rebuild_failed(root, { [0] = "cosmic", "test" },
      "checker: T (unresolved generic)", true, {}))
  end)
  assert(code == "3", code)
  assert(all:find("checker: T (unresolved generic)", 1, true), all)
  assert(all:find("bin/zig build boot failed", 1, true), all)
end

--- A failure while the compiler has not moved is the tree's own error:
--- nothing boots.
local function test_rebuild_failed_does_not_boot_while_the_compiler_stands(tmp: string)
  local root = tree_with_zig(tmp, 0)
  local code = reboot.rebuild_failed(root, { [0] = "cosmic", "test" },
    "a type error in the tree", false, {})
  assert(code == 3, code)
  assert(Fs.read(root .. "/bin/ran") == nil, "a failure of the tree's own booted")
end

--- COSMIC_AUTO_BOOT=0 refuses, exit 3, in place of the boot.
local function test_rebuild_failed_refuses_when_told_not_to_boot(tmp: string)
  local root = tree_with_zig(tmp, 0)
  local code = reboot.rebuild_failed(root, { [0] = "cosmic", "test" },
    "checker: T (unresolved generic)", true, { COSMIC_AUTO_BOOT = "0" })
  assert(code == 3, code)
  assert(Fs.read(root .. "/bin/ran") == nil, "booted although told not to")
end

--- Only a binary under the tree's o/ is its own tool, judged by the
--- path it was started as, its directory resolved: a link into the
--- build directory from outside is outside, a name in it is inside even
--- when the file is gone (renamed or removed while it runs), and a
--- directory link into it counts. A tree with no build directory has no
--- tool of its own to judge.
local function test_own_tool_is_a_binary_under_the_trees_outputs(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root))
  local layout = paths.resolve(root)
  local sanitized = paths.under(layout.sanitized)
  assert(Fs.mkdirs(layout.bin))
  assert(Fs.mkdirs(sanitized.bin))
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  for _, path in ipairs({ layout.tool, sanitized.tool, tmp .. "/elsewhere/cosmic" }) do
    assert(Fs.write(path, "binary", 0x1ed))
  end
  assert(Fs.symlink(layout.tool, tmp .. "/elsewhere/into"))
  assert(Fs.symlink(layout.bin, tmp .. "/bin-link"))
  local cases: {string:boolean} = {
    [layout.tool] = true,
    [sanitized.tool] = true,
    [layout.bin .. "/gone"] = true,
    [tmp .. "/bin-link/cosmic"] = true,
    [tmp .. "/elsewhere/into"] = false,
    [tmp .. "/elsewhere/cosmic"] = false,
  }
  for path, want in pairs(cases) do
    local own, trouble = reboot.own_tool(root, path)
    assert(own == want, path .. ": " .. tostring(own) .. " " .. trouble)
  end
  local none, missing = reboot.own_tool(tmp .. "/elsewhere", tmp .. "/elsewhere/cosmic")
  assert(none == nil and missing:find(paths.resolve(tmp .. "/elsewhere").directory, 1, true), missing)
end

--- A tool carries a tree's code when every module and main of the tree
--- is one it carries with the same source ([`reboot.carries_tree_code`]),
--- whatever its fingerprint says: a tree of this binary's own
--- build.bind does, and not once that source is edited, nor once the
--- tree holds a module the binary does not carry. A tree with no module
--- proves nothing.
local function test_carries_tree_code_compares_every_module(tmp: string)
  local function carries(): boolean
    local handle = assert(work.open(tmp))
    assert(work.stage(handle, true))
    local answer = reboot.carries_tree_code(handle)
    assert(work.close(handle))
    return answer
  end
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(not carries(), "a tree with no module carried the tree's code")
  local source = assert(Store.source("build.bind"))
  assert(Fs.write(tmp .. "/build/bind.tl", source))
  assert(carries(), "the binary's own build.bind did not carry the tree's code")
  assert(Fs.write(tmp .. "/build/bind_test.tl", "local function test_nothing() end\n"))
  assert(carries(), "a test module, which no tool carries, was held against it")
  assert(Fs.write(tmp .. "/build/bind.tl", source .. "-- edited\n"))
  assert(not carries(), "an edited module carried the tree's code")
  assert(Fs.write(tmp .. "/build/bind.tl", source))
  assert(Fs.write(tmp .. "/build/nowhere.tl", "return {}\n"))
  assert(not carries(), "a module the binary does not carry carried the tree's code")
end

--- A rebuilt tool carries the running binary's web assets; from a binary
--- from before the table it takes the vendored trees', and a tree with
--- none (a project's) leaves it with none.
local function test_web_assets_fall_back_to_the_vendored_trees_for_an_older_binary(tmp: string)
  assert(Fs.mkdirs(tmp .. "/vendor/htmx/dist"))
  assert(Fs.write(tmp .. "/vendor/htmx/PIN", "version 9.9.9\nurl x\n"))
  assert(Fs.write(tmp .. "/vendor/htmx/dist/htmx.min.js", "vendored"))
  assert(Fs.mkdirs(tmp .. "/vendor/htmx-ext-sse/dist"))
  assert(Fs.write(tmp .. "/vendor/htmx-ext-sse/PIN", "version 8.8.8\nurl x\n"))
  assert(Fs.write(tmp .. "/vendor/htmx-ext-sse/dist/sse.min.js", "sse"))
  local older = assert(Sqlite.memory())
  local fallen = assert(reboot.web_assets(older, tmp))
  assert(#fallen == 2 and fallen[2].name == "htmx.min.js" and fallen[2].version == "9.9.9" and
      fallen[2].data == "vendored", "an older binary's rebuild took the tree's files")
  local bare = assert(reboot.web_assets(older, tmp .. "/nowhere"))
  assert(#bare == 0, "a tree with no vendor/ leaves none")
  assert(older:close())

  local newer = assert(Sqlite.memory())
  assert(newer:exec("CREATE TABLE web_assets (name TEXT PRIMARY KEY NOT NULL, data BLOB NOT NULL, " ..
      "sha256 TEXT NOT NULL, sha384 TEXT NOT NULL, version TEXT NOT NULL)"))
  assert(newer:exec("INSERT INTO web_assets VALUES ('htmx.min.js', x'01', 'a', 'b', '1.0.0')"))
  local kept = assert(reboot.web_assets(newer, tmp))
  assert(#kept == 1 and kept[1].version == "1.0.0", "the binary's own files are kept")
  assert(newer:close())
end

--- The check before a verb that only reads waits for no run that holds
--- the working database of cosmic's own tree: that run checks the tool
--- against the same tree, and the verb goes on at once.
local function test_a_reading_verbs_check_waits_for_no_run_holding_the_database(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/importer.tl", "return {}\n"))
  assert(work.close((assert(work.open(tmp)))))
  local held = assert(Sqlite.open(paths.under((assert(paths.directory(tmp)))).working, { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local started = Clock.monotonic_ns()
  local code = reboot.stale_exit({ [1] = "docs", [2] = "Fs.read" }, true, tmp)
  local took = Clock.monotonic_ns() - started
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  assert(code == nil, tostring(code))
  assert(took < Clock.seconds(10), tostring(took) .. " ns")
end

--- Where no run holds the working database, the check before a verb
--- that only reads is the check before any verb: it stages the tree and
--- holds the tool to it. The test runner's tool is not the tree's own
--- ([`reboot.own_tool`]), so it refuses, and rebuilds nothing.
local function test_a_reading_verbs_check_holds_the_tool_to_the_tree_when_the_lock_is_free(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/importer.tl", "return {}\n"))
  assert(work.close((assert(work.open(tmp)))))
  local code = reboot.stale_exit({ [1] = "docs", [2] = "Fs.read" }, true, tmp)
  assert(code == 3, tostring(code))
  local db = assert(Sqlite.open(paths.under((assert(paths.directory(tmp)))).working))
  local rows = assert(Sqlite.text_rows(db, "SELECT path FROM files WHERE path = 'build/importer.tl'"))
  assert(db:close())
  assert(#rows == 1, "the tree is staged")
end

--- The working database of a tree like cosmic's own at `tmp`, made and
--- then stamped with another schema, as another tool's would be: its path.
local function own_tree_of_another_schema(tmp: string): string
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/importer.tl", "return {}\n"))
  local made = assert(work.open(tmp))
  assert(Sqlite.run(made.db, "UPDATE meta SET value = 'another' WHERE key = 'schema'"))
  local path = made.dir .. "/build.db"
  assert(work.close(made))
  return path
end

--- Where no run holds a working database of another schema, the check
--- before a verb that only reads is the check before any verb: it makes
--- the file again as a build does, stages the tree and holds the tool to
--- it, so a stale tool rebuilds rather than going on with its own code.
--- The test runner's tool is not the tree's own ([`reboot.own_tool`]),
--- so it refuses.
local function test_a_reading_verbs_check_holds_the_tool_to_the_tree_over_a_free_database_of_another_schema(tmp: string)
  local path = own_tree_of_another_schema(tmp)
  local code = reboot.stale_exit({ [1] = "docs", [2] = "Fs.read" }, true, tmp)
  assert(code == 3, tostring(code))
  local db = assert(Sqlite.open(path))
  local schema = assert(Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'schema'"))
  local rows = assert(Sqlite.text_rows(db, "SELECT path FROM files WHERE path = 'build/importer.tl'"))
  assert(db:close())
  assert(assert(schema[1]):text(1) ~= "another", "the file of another schema was kept")
  assert(#rows == 1, "the tree is staged")
end

--- Where another run holds a working database of another schema, the
--- check before a verb that only reads is skipped, and says the file is
--- of another schema, which the verb then reads none of, rather than that
--- it reads what that run last committed. The file is left where it is.
local function test_a_reading_verbs_check_says_a_held_database_is_of_another_schema(tmp: string)
  local path = own_tree_of_another_schema(tmp)
  local before = assert(Fs.stat(path)).ino
  local held = assert(Sqlite.open(path, { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local code, all = complaints(function(): string
    return tostring(reboot.stale_exit({ [1] = "docs", [2] = "Fs.read" }, true, tmp))
  end)
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  assert(code == "nil", code)
  assert(all:find("docs: " .. path .. " is of schema another", 1, true), all)
  assert(not all:find("reading what it last committed", 1, true), all)
  assert(assert(Fs.stat(path)).ino == before, "the file was removed")
end

--- A lookup's own build ([`rebuild.here`]) that finds the working
--- database of another schema builds nothing in it, writes no projection
--- and leaves the file where it is, saying it is of another schema rather
--- than that another run holds it. Here, beside the check before the
--- lookup, which says the same.
local function test_a_lookups_build_leaves_a_database_of_another_schema(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local made = assert(work.open(root))
  assert(Sqlite.run(made.db, "UPDATE meta SET value = 'another' WHERE key = 'schema'"))
  assert(work.close(made))
  assert(Fs.write(root .. "/a.tl", "return {}\n"))
  local layout = paths.resolve(root)
  local before = assert(Fs.stat(layout.working)).ino
  local _, all = complaints(function(): string
    local built, trouble = rebuild.here("docs", false, root)
    assert(built, trouble)
    return trouble
  end)
  assert(all:find("docs: " .. layout.working .. " is of schema another", 1, true), all)
  assert(assert(Fs.stat(layout.working)).ino == before, "the file was removed")
  assert(Fs.exists(layout.projection) == false, "a projection was written")
  local db = assert(Sqlite.open(layout.working))
  local rows = assert(Sqlite.text_rows(db, "SELECT path FROM inputs"))
  assert(db:close())
  assert(#rows == 0, "staged " .. tostring(#rows) .. " files in it")
end
