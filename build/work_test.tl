-- The tests of [`build.work`] that start the program, a build or a
-- `cosmic test` beside this process, are build/work_tool_test.tl's.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local work = require("build.work")

local function count(db: Sqlite.Handle, table_name: string): integer
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM " .. table_name))
  return math.tointeger(tonumber(rows[1][1])) as integer
end

--- A run waits for another run of the tree to end its transaction on
--- o/build.db as long as that run may hold it: through a stale tool's
--- whole rebuild of itself, which takes more than a minute on a loaded
--- host. Waiting only SQLite's 60 s, a run started beside a rebuilding
--- one fails with "database is locked" (ci/fixtures/self_rebuild_test.tl's
--- concurrent runs).
local function test_a_run_waits_for_another_past_a_rebuild(tmp: string)
  local handle = assert(work.open(tmp))
  local rows = assert(Sqlite.text_rows(handle.db, "PRAGMA busy_timeout"))
  local waits = math.tointeger(tonumber(rows[1][1])) or 0
  assert(waits >= 10 * 60 * 1000, "o/build.db waits only " ..
    tostring(waits) .. " ms for another run")
  assert(work.close(handle))
end

local function test_recording_error_rolls_back_every_table(tmp: string)
  local handle = assert(work.open(tmp))
  assert(work.commit(handle))
  assert(handle.db:exec([[CREATE TEMP TRIGGER reject_coverage
    BEFORE INSERT ON coverage BEGIN SELECT RAISE(ABORT, 'injected'); END]]))
  assert(work.begin(handle))
  assert(handle.db:exec("INSERT INTO runs VALUES ('p', 't', 1, '', 1, 'k', 1, 1)"))
  assert(handle.db:exec("INSERT INTO verdicts VALUES ('k', 1, 1, 1, 1)"))
  assert(handle.db:exec("INSERT INTO test_runs VALUES (1)"))
  local inserted, trouble = handle.db:exec("INSERT INTO coverage VALUES (1, 'p', 1, 1)")
  assert(not inserted and trouble:find("injected", 1, true) ~= nil)
  assert(work.abort(handle))
  local reopened = assert(Sqlite.open(tmp .. "/o/build.db", false))
  for _, table_name in ipairs({
    "runs", "verdicts", "test_runs", "coverage", "coverage_by_test",
  }) do
    assert(count(reopened, table_name) == 0, table_name .. " must roll back")
  end
  assert(reopened:close())
end

local function test_assertion_failure_records_atomically(tmp: string)
  local handle = assert(work.open(tmp))
  assert(work.commit(handle))
  assert(work.begin(handle))
  assert(handle.db:exec("INSERT INTO runs VALUES ('p', 't', 0, 'asserted', 1, 'k', 1, 1)"))
  assert(handle.db:exec("INSERT INTO verdicts VALUES ('k', 0, 1, 1, 1)"))
  assert(handle.db:exec("INSERT INTO test_runs VALUES (1)"))
  assert(handle.db:exec("INSERT INTO coverage VALUES (1, 'p', 1, 1)"))
  assert(work.close(handle))

  local reopened = assert(Sqlite.open(tmp .. "/o/build.db", false))
  assert(count(reopened, "runs") == 1)
  assert(count(reopened, "verdicts") == 1)
  assert(count(reopened, "test_runs") == 1)
  assert(count(reopened, "coverage") == 1)
  assert(reopened:close())
end

--- A warm database of an older symbol schema is recreated before any
--- cached parse or reference row is trusted under the current one.
local function test_symbol_schema_upgrade_discards_old_analysis(tmp: string)
  local old = assert(work.open(tmp))
  assert(work.commit(old))
  assert(Sqlite.run(old.db,
    "UPDATE meta SET value = '13' WHERE key = 'schema'"))
  assert(Sqlite.run(old.db,
    "INSERT INTO parsed (source_hash, has_return, export) VALUES ('old', 1, 'Old')"))
  assert(Sqlite.run(old.db,
    "INSERT INTO refs (source_hash, ordinal, module, member, line) " ..
    "VALUES ('old', 1, 'cosmic.fs', 'read', 1)"))
  assert(old.db:close())

  local upgraded = assert(work.open(tmp))
  assert(count(upgraded.db, "parsed") == 0)
  assert(count(upgraded.db, "refs") == 0)
  local columns = assert(Sqlite.text_rows(upgraded.db, "PRAGMA table_info(docs)"))
  local names: {string: boolean} = {}
  for _, row in ipairs(columns) do names[row[2]] = true end
  assert(names["source_symbol"] and names["exported"])
  assert(work.close(upgraded))
end

--- The bytes `files` holds for one staged path.
local function staged_bytes(db: Sqlite.Handle, path: string): string
  local rows = assert(Sqlite.text_rows(db,
    "SELECT CAST(data AS TEXT) FROM files WHERE path = ?1", { { text = path } }))
  return rows[1][1]
end

--- A file staged within the settle window is read again next time even
--- when a same-size rewrite in place then stamps it with the epoch, a
--- time a tool normalizing times writes: an unsettled row's time must
--- not match any stat, the epoch's included.
local function test_an_unsettled_row_is_read_again_at_the_epoch(tmp: string)
  local path = tmp .. "/probe.tl"
  assert(Fs.write(path, "return 1\n"))
  -- An hour ahead, so it is unsettled however long staging takes.
  assert(Fs.set_mtime(path, Time.now_ns() // 1000000000 + 3600, 0))
  local handle = assert(work.open(tmp))
  assert(work.stage(handle, false))
  assert(staged_bytes(handle.db, "probe.tl") == "return 1\n")
  local unsettled = assert(Sqlite.text_rows(handle.db,
    "SELECT mtime_ns IS NULL FROM files WHERE path = 'probe.tl'"))
  assert(unsettled[1][1] == "1", "the first stage must leave the row unsettled")
  local before = assert(Fs.stat(path))

  local fd = assert(Fs.open_write(path))
  assert(Fs.put(fd, "return 2\n"))
  assert(Fs.close(fd))
  assert(Fs.set_mtime(path, 0, 0))
  local after = assert(Fs.stat(path))
  assert(after.ino == before.ino and after.size == before.size)

  local staged = assert(work.stage(handle, false))
  assert(staged.read == 1, "an unsettled row must count as moved")
  assert(staged_bytes(handle.db, "probe.tl") == "return 2\n")
  assert(work.close(handle))
end

--- A file whose time is the epoch has settled, and its row is trusted:
--- staging it again reads nothing.
local function test_a_settled_epoch_time_is_trusted(tmp: string)
  local path = tmp .. "/probe.tl"
  assert(Fs.write(path, "return 1\n"))
  assert(Fs.set_mtime(path, 0, 0))
  local handle = assert(work.open(tmp))
  local first = assert(work.stage(handle, false))
  assert(first.read == 1)
  local second = assert(work.stage(handle, false))
  assert(second.read == 0, "a settled epoch row must stand")
  assert(work.close(handle))
end

--- A project whose module directory and one test are links into a
--- tree beside it, and a `loop -> .`: `tmp/project`.
local function linked_project(tmp: string): string
  local project = tmp .. "/project"
  assert(Fs.mkdirs(tmp .. "/shared/lib"))
  assert(Fs.mkdirs(project))
  assert(Fs.write(tmp .. "/shared/lib/util.tl", "local util = {}\nutil.answer = 42\nreturn util\n"))
  assert(Fs.write(tmp .. "/shared/linked_test.tl",
    'local util = require("lib.util")\n\nlocal function test_linked()\n  assert(util.answer == 42)\nend\n'))
  assert(Fs.write(project .. "/main_test.tl",
    'local util = require("lib.util")\n\nlocal function test_main()\n  assert(util.answer == 42)\nend\n'))
  assert(Fs.symlink("../shared/lib", project .. "/lib"))
  assert(Fs.symlink("../shared/linked_test.tl", project .. "/linked_test.tl"))
  assert(Fs.symlink(".", project .. "/loop"))
  return project
end

--- Staging takes a link for what it leads to: a module directory and a
--- test reached through links are staged under the links' paths, and a
--- loop of links ends its branch rather than the stage.
local function test_stage_takes_a_link_for_what_it_leads_to(tmp: string)
  local project = linked_project(tmp)
  local handle = assert(work.open(project))
  assert(work.stage(handle, false))
  assert(staged_bytes(handle.db, "lib/util.tl") == assert(Fs.read(tmp .. "/shared/lib/util.tl")))
  assert(staged_bytes(handle.db, "linked_test.tl") ~= nil, "the linked test is staged")
  local looped = assert(Sqlite.text_rows(handle.db,
    "SELECT count(*) FROM files WHERE path LIKE 'loop/%'"))
  assert(looped[1][1] == "0", "nothing is staged through the loop")
  assert(work.close(handle))
end

--- Stages `project`, then refuses once `link` leads to `target`: the
--- refusal names the link and leaves what the first stage staged.
local function refused_above(project: string, target: string, link: string)
  local handle = assert(work.open(project))
  assert(work.stage(handle, false))
  local before = assert(Sqlite.text_rows(handle.db, "SELECT count(*) FROM files"))
  assert(before[1][1] ~= "0")
  assert(Fs.symlink(target, project .. "/" .. link))
  local staged, trouble = work.stage(handle, false)
  assert(staged == nil, "a link above the root is refused")
  assert(trouble:find(link .. ": a link to ", 1, true), trouble)
  assert(trouble:find("above the root", 1, true), trouble)
  local after = assert(Sqlite.text_rows(handle.db, "SELECT count(*) FROM files"))
  assert(after[1][1] == before[1][1], "the refusal leaves the rows staged before")
  assert(work.close(handle))
end

--- A link that leads above the root would stage all that lies under
--- where it leads; staging refuses it and names it.
local function test_stage_refuses_a_link_above_the_root(tmp: string)
  local project = linked_project(tmp)
  assert(Fs.mkdirs(project .. "/sub"))
  refused_above(project, "../..", "sub/ws")
end

--- As it refuses one reached through another link, and one to `/`.
local function test_stage_refuses_a_link_above_the_root_through_a_link(tmp: string)
  local project = linked_project(tmp)
  assert(Fs.mkdirs(tmp .. "/x"))
  assert(Fs.symlink("../x", project .. "/a"))
  refused_above(project, "../..", "a/up")
end

local function test_stage_refuses_a_link_to_the_file_system_root(tmp: string)
  local project = linked_project(tmp)
  refused_above(project, "/", "top")
end

--- The zones a boot reads from a tree replace whatever the working
--- database held, stay blobs, and read back out of any database that
--- has them -- and out of one with no table for them, as none.
local function test_zoneinfo_is_replaced_whole_and_read_back(tmp: string)
  assert(Fs.mkdirs(tmp .. "/zoneinfo/Europe"))
  assert(Fs.write(tmp .. "/zoneinfo/UTC", "TZif utc"))
  assert(Fs.write(tmp .. "/zoneinfo/Europe/Paris", "TZif\0paris"))
  local zones = assert(work.read_zoneinfo(tmp .. "/zoneinfo"))
  assert(zones["UTC"] == "TZif utc" and zones["Europe/Paris"] == "TZif\0paris")
  local missing, trouble = work.read_zoneinfo(tmp .. "/nowhere")
  assert(missing == nil and trouble ~= "")

  local handle = assert(work.open(tmp))
  assert(work.put_zoneinfo(handle, { ["Old/Zone"] = "gone" }))
  assert(work.put_zoneinfo(handle, zones))
  local back = assert(work.zoneinfo_of(handle.db))
  assert(back["Old/Zone"] == nil, "a zone the tree no longer has is gone")
  assert(back["Europe/Paris"] == "TZif\0paris" and back["UTC"] == "TZif utc")
  local rows = assert(Sqlite.text_rows(handle.db,
    "SELECT group_concat(name || ' ' || typeof(data), ',' ORDER BY rowid) FROM zoneinfo"))
  assert(rows[1][1] == "Europe/Paris blob,UTC blob", rows[1][1])
  assert(work.close(handle))

  local older = assert(Sqlite.memory())
  local none = assert(work.zoneinfo_of(older))
  assert(next(none) == nil)
  assert(older:close())
end

--- The compiler is one row, whatever file an older build named it by:
--- putting one replaces a row left under `o/vendor/tl/tl.lua`, so no
--- working database holds two.
local function test_putting_the_compiler_replaces_an_older_row(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root"))
  local handle = assert(work.open(tmp .. "/root"))
  assert(Sqlite.run(handle.db,
    "INSERT INTO derived (file, path, kind, origin, from_hash, source, " ..
    "source_hash) VALUES ('o/vendor/tl/tl.lua', 'vendor.tl', 'vendor', " ..
    "'vendor', 'old', 'return {}', 'old')", {}))
  assert(work.put_compiler(handle, "return { new = true }"))
  local rows = assert(Sqlite.text_rows(handle.db,
    "SELECT file, source FROM derived WHERE origin = 'vendor'"))
  assert(#rows == 1 and rows[1][2] == "return { new = true }",
    "the compiler is one row: " .. tostring(#rows))
  assert(work.close(handle))
end

--- Stages a tree laid out as cosmic's own and answers its `boot`
--- fingerprint.
local function boot_of(root: string): string
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local fingerprint = assert(work.record_fingerprint(handle))
  assert(work.close(handle))
  return fingerprint.boot
end

--- `boot_hash` follows every module the tool carries, wherever it
--- sits: an edit to one under eval/ or test/portable, trees none of
--- the tool's C is in, moves it, and an edit to a test or testdata
--- beside them, which the tool never carries, does not.
local function test_a_carried_module_outside_the_tool_trees_moves_boot_hash(tmp: string)
  local root = tmp .. "/root"
  local files: {string:string} = {
    ["build/x.tl"] = "return {}\n",
    ["eval/summarize.tl"] = "return {}\n",
    ["test/portable/init.tl"] = "return {}\n",
    ["test/portable/tool_test.tl"] = "local function test_x() end\n",
    ["eval/testdata/case.tl"] = "return {}\n",
  }
  for path, data in pairs(files) do
    assert(Fs.mkdirs(root .. "/" .. path:match("^(.*)/")))
    assert(Fs.write(root .. "/" .. path, data))
  end
  local before = boot_of(root)
  assert(boot_of(root) == before, "an unchanged tree keeps its boot_hash")
  for _, path in ipairs({ "test/portable/tool_test.tl", "eval/testdata/case.tl" }) do
    assert(Fs.write(root .. "/" .. path, "return { edited = true }\n"))
    assert(boot_of(root) == before, path .. " is not carried, and moves nothing")
  end
  for _, path in ipairs({ "eval/summarize.tl", "test/portable/init.tl" }) do
    assert(Fs.write(root .. "/" .. path, "return { edited = true }\n"))
    local after = boot_of(root)
    assert(after ~= before, path .. " is carried, and moves boot_hash")
    before = after
  end
end
