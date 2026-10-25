-- The tests of [`build.work`] that start the program, a build or a
-- `cosmic test` beside this process, are build/work_tool_test.tl's and
-- build/work_nested_tool_test.tl's.

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local identity = require("build.identity")
local work = require("build.work")
local build_paths = require("build.paths")

--- `root`'s build directory ([`build.paths`]), made, with `root` made
--- first where it is not there yet.
local function build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

local function count(db: Sqlite.Handle, table_name: string): integer
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM " .. table_name))
  return math.tointeger(tonumber(rows[1]:text(1))) as integer
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
  local reopened = assert(Sqlite.open(build_dir(tmp) .. "/build.db"))
  for _, table_name in ipairs({
      "runs", "verdicts", "test_runs", "coverage", "coverage_by_test",
  }) do
    assert(count(reopened, table_name) == 0, table_name .. " must roll back")
  end
  assert(reopened:close())
end

--- A fresh working database's tables go in in one transaction, so a
--- statement that fails leaves none of them, where each in a transaction
--- of its own would have left those before it (and paid a sync apiece).
local function test_a_fresh_schema_is_made_in_one_transaction(tmp: string)
  work.schema[#work.schema + 1] = "CREATE TABLE fails ("
  local ran, handle, trouble = pcall(work.open, tmp)
  work.schema[#work.schema] = nil
  assert(ran and handle == nil and trouble ~= "", "the planted statement fails the open")
  local db = assert(Sqlite.open(build_dir(tmp) .. "/build.db"))
  assert(count(db, "sqlite_master") == 0, "a failed fresh schema leaves no table")
  assert(db:close())
  -- And the schema goes in whole once nothing fails.
  local opened = assert(work.open(tmp))
  assert(count(opened.db, "files") == 0)
  assert(work.close(opened))
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

  local reopened = assert(Sqlite.open(build_dir(tmp) .. "/build.db"))
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
  local names: mut {string: boolean} = {}
  for _, row in ipairs(columns) do names[row:text(2)] = true end
  assert(names["source_symbol"] and names["exported"])
  assert(work.close(upgraded))
end

--- The journal mode of the file at `path`, as a reader opening it sees.
local function journal_mode(path: string): string
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "PRAGMA journal_mode"))
  assert(db:close())
  return assert(rows[1]):text(1)
end

--- A working database is in write-ahead mode, and one made in rollback
--- mode, by a build before this one, is put in it at its next writable
--- open.
local function test_a_rollback_mode_database_is_put_in_write_ahead_mode(tmp: string)
  local path = build_dir(tmp) .. "/build.db"
  assert(work.close((assert(work.open(tmp)))))
  assert(journal_mode(path) == "wal", journal_mode(path))
  local db = assert(Sqlite.open(path, { writable = true }))
  local set = assert(assert(Sqlite.text_rows(db, "PRAGMA journal_mode = DELETE"))[1]):text(1)
  assert(set == "delete", set)
  assert(db:close())
  assert(journal_mode(path) == "delete", journal_mode(path))
  local reopened = assert(work.open(tmp))
  local mode = assert(assert(Sqlite.text_rows(reopened.db, "PRAGMA journal_mode"))[1]):text(1)
  assert(mode == "wal", mode)
  assert(work.close(reopened))
  assert(journal_mode(path) == "wal", journal_mode(path))
end

--- A commit is in the file itself, not in its write-ahead log alone,
--- while the run that made it keeps its handle open, as `cosmic test`
--- does while its tests run: a reader of the file alone, as
--- [`Store.attach`] opens it, reads it.
local function test_a_commit_is_in_the_file_while_its_run_goes_on(tmp: string)
  local handle = assert(work.open(tmp))
  assert(Sqlite.run(handle.db, "INSERT INTO meta (key, value) VALUES ('marker', 'committed')"))
  assert(work.commit(handle))
  local alone = assert(Sqlite.open(build_dir(tmp) .. "/build.db", { immutable = true }))
  -- Without the copy into the file, it holds no table yet.
  local rows = assert(Sqlite.text_rows(alone, "SELECT value FROM meta WHERE key = 'marker'"))
  assert(alone:close())
  assert(work.close(handle))
  assert(#rows == 1 and assert(rows[1]):text(1) == "committed", tostring(#rows))
end

--- An open that waits for no run answers at once, with no handle, while
--- another run holds the write lock, and opens the database once it is
--- free.
local function test_an_open_that_waits_for_no_run_finds_one_holding_it(tmp: string)
  assert(work.close((assert(work.open(tmp)))))
  local held = assert(Sqlite.open(build_dir(tmp) .. "/build.db", { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local started = Clock.monotonic_ns()
  local busy = assert(work.try_open(tmp))
  local took = Clock.monotonic_ns() - started
  assert(busy.handle == nil, "opened while another run holds it")
  assert(took < Clock.seconds(5), tostring(took) .. " ns")
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  local free = assert(work.try_open(tmp))
  assert(work.close((assert(free.handle))))
end

--- A working database at `tmp` stamped with another schema, as another
--- tool's would be, holding a row a remade file would not: its path.
local function of_another_schema(tmp: string): string
  local path = build_dir(tmp) .. "/build.db"
  local made = assert(work.open(tmp))
  assert(Sqlite.run(made.db, "UPDATE meta SET value = 'another' WHERE key = 'schema'"))
  assert(Sqlite.run(made.db, "INSERT INTO meta (key, value) VALUES ('marker', 'kept')"))
  assert(work.close(made))
  return path
end

--- The device and inode of the file at `path`.
local function inode_of(path: string): string
  local st = assert(Fs.stat(path))
  return tostring(st.dev) .. ":" .. tostring(st.ino)
end

--- The value `meta` holds for `key` in the file at `path`, read alone.
local function meta_of(path: string, key: string): string
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = '" .. key .. "'"))
  assert(db:close())
  if #rows == 0 then return "" end
  return assert(rows[1]):text(1)
end

--- An open that waits for no run, which may be a run of an older tool,
--- answers at once with no handle where the file is of another schema
--- and another run holds its write lock, as a newer tool building in it
--- would: it leaves the file where it is, for that run goes on writing
--- to it.
local function test_an_open_that_waits_for_no_run_never_removes_a_held_file_of_another_schema(tmp: string)
  local path = of_another_schema(tmp)
  local before = inode_of(path)
  local held = assert(Sqlite.open(path, { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local started = Clock.monotonic_ns()
  local opening, trouble = work.try_open(tmp)
  local took = Clock.monotonic_ns() - started
  local after = inode_of(path)
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  assert(opening ~= nil, trouble)
  assert(opening.handle == nil, "opened a file of another schema")
  assert(after == before, "the file another run holds was removed")
  assert(meta_of(path, "marker") == "kept")
  assert(took < Clock.seconds(5), tostring(took) .. " ns")
end

--- An open that waits for no run reads nothing of a file of another
--- schema, holding its write lock or not: it neither removes it nor
--- writes this module's tables into it, and answers the schema it found.
local function test_an_open_that_waits_for_no_run_reads_nothing_of_another_schema(tmp: string)
  local path = of_another_schema(tmp)
  local before = inode_of(path)
  local dropped = assert(Sqlite.open(path, { writable = true }))
  assert(dropped:exec("DROP TABLE files"))
  assert(dropped:close())
  local opening = assert(work.try_open(tmp))
  assert(opening.handle == nil, "opened a file of another schema")
  assert(opening.other_schema == "another", tostring(opening.other_schema))
  assert(inode_of(path) == before, "the file was removed")
  assert(meta_of(path, "schema") == "another" and meta_of(path, "marker") == "kept")
  local db = assert(Sqlite.open(path))
  assert(count(db, "sqlite_master WHERE name = 'files'") == 0, "a table was made in it")
  assert(db:close())
  -- A run that waits for others makes it again, of this module's schema.
  local remade = assert(work.open(tmp))
  assert(work.close(remade))
  -- By its rows, not its inode, which a file made at once after the old
  -- one is removed may be given again.
  assert(meta_of(path, "marker") == "", "the file of another schema was kept")
  local again = assert(work.try_open(tmp))
  assert(again.other_schema == nil)
  assert(work.close((assert(again.handle))))
end

--- An open that remakes a file of another schema waiting for no run
--- leaves it to a run that holds the checkout's rebuild lock, as a `cosmic
--- test` run does from its compile's commit to its records' own
--- transaction: the file's write lock is free between the two, and a
--- file removed then is one that run goes on writing its records to,
--- unlinked, and loses.
local function test_a_remaking_open_leaves_a_file_a_run_holding_the_rebuild_lock_writes_to(tmp: string)
  local path = build_dir(tmp) .. "/build.db"
  local running = assert(work.open(tmp))
  assert(Sqlite.run(running.db, "UPDATE meta SET value = 'another' WHERE key = 'schema'"))
  assert(work.commit(running))
  -- Held as another process holds the rebuild lock
  -- ([`build.rebuild_lock`]): one this process holds through that
  -- module is one it takes as its own.
  local lock = assert(sys.open(build_paths.resolve(tmp).lock, sys.O_RDWR | sys.O_CREAT, 0x1a4))
  assert(sys.flock(lock, "exclusive"))
  local tried = assert(work.try_open_remaking(tmp))
  assert(tried.handle == nil, "opened a file of another schema another run writes to")
  assert(tried.other_schema == "another", tostring(tried.other_schema))
  assert(work.begin(running))
  assert(Sqlite.run(running.db, "INSERT INTO meta (key, value) VALUES ('marker', 'kept')"))
  assert(work.close(running))
  assert(sys.close(lock))
  assert(meta_of(path, "marker") == "kept", "the run's records were lost to a removed file")
end

--- A read of the working database answers at once, with the last
--- commit, while a run holds its write transaction open with more
--- written than its cache holds. In rollback mode that run's spill holds
--- the file whole, and the read would wait for the run to end; the
--- reader here waits two seconds at most, so a read held off fails.
local function test_a_read_answers_at_once_while_a_run_writes(tmp: string)
  local handle = assert(work.open(tmp))
  assert(Sqlite.run(handle.db, "INSERT INTO meta (key, value) VALUES ('marker', 'committed')"))
  assert(work.commit(handle))
  assert(work.begin(handle))
  assert(Sqlite.run(handle.db, "UPDATE meta SET value = 'uncommitted' WHERE key = 'marker'"))
  -- A cache of a few pages, and far more written than it holds: spilled.
  assert(handle.db:exec("PRAGMA cache_size = 10"))
  assert(handle.db:exec("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n " ..
      "WHERE i < 4000) INSERT INTO meta (key, value) SELECT 'filler ' || i, " ..
      "hex(randomblob(512)) FROM n"))
  local started = Clock.monotonic_ns()
  local reader = assert(Sqlite.open(build_dir(tmp) .. "/build.db"))
  reader:busy_timeout(Clock.seconds(2))
  local rows = assert(Sqlite.text_rows(reader, "SELECT value FROM meta WHERE key = 'marker'"))
  local fillers = assert(Sqlite.text_rows(reader,
    "SELECT count(*) FROM meta WHERE key LIKE 'filler %'"))
  local took = Clock.monotonic_ns() - started
  assert(reader:close())
  assert(work.abort(handle))
  local marker = assert(rows[1]):text(1)
  assert(marker == "committed", marker)
  assert(assert(fillers[1]):text(1) == "0", "no uncommitted row is read")
  assert(took < Clock.seconds(1), "the read took " .. tostring(took) .. " ns")
end

--- The bytes `files` holds for one staged path.
local function staged_bytes(db: Sqlite.Handle, path: string): string
  local rows = assert(Sqlite.text_rows(db,
    "SELECT CAST(data AS TEXT) FROM files WHERE path = ?1", { { text = path } }))
  return rows[1]:text(1)
end

--- Stage after the timestamp tick has settled, without waiting on the host clock.
local function stage_settled(handle: work.Handle, own_tree?: boolean): work.Staged
  local now = Clock.now_ns
  Clock.now_ns = function(): integer return now() + Clock.seconds(3) end
  local ok, staged, trouble = pcall(work.stage, handle, own_tree or false)
  Clock.now_ns = now
  assert(ok, tostring(staged))
  return (assert(staged, trouble))
end

--- Give the tested paths distinct change-time ticks even on a coarse filesystem.
local function with_change_time(paths: {string}, check: function(function()))
  local tracked: mut {string:boolean} = {}
  for _, path in ipairs(paths) do tracked[path] = true end
  local stat = Fs.stat
  local tick = { value = 1 }
  Fs.stat = function(path: string): sys.Stat?, string
    local st, trouble = stat(path)
    if st ~= nil and tracked[path] then
      st.ctime = 100
      st.ctime_ns = tick.value
    end
    return st, trouble
  end
  local ok, trouble = pcall(function(): boolean
    check(function() tick.value = tick.value + 1 end)
    return true
  end)
  Fs.stat = stat
  assert(ok, tostring(trouble))
end

--- A file staged within the settle window is read again next time even
--- when a same-size rewrite in place then stamps it with the epoch, a
--- time a tool normalizing times writes: an unsettled row's time must
--- not match any stat, the epoch's included.
local function test_an_unsettled_row_is_read_again_at_the_epoch(tmp: string)
  local path = tmp .. "/probe.tl"
  assert(Fs.write(path, "return 1\n"))
  -- An hour ahead, so it is unsettled however long staging takes.
  assert(Fs.set_mtime(path, Clock.now_ns() // 1000000000 + 3600, 0))
  local handle = assert(work.open(tmp))
  assert(work.stage(handle, false))
  assert(staged_bytes(handle.db, "probe.tl") == "return 1\n")
  local unsettled = assert(Sqlite.text_rows(handle.db,
    "SELECT mtime_ns IS NULL FROM files WHERE path = 'probe.tl'"))
  assert(unsettled[1]:text(1) == "1", "the first stage must leave the row unsettled")
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
  local first = stage_settled(handle)
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
  assert(looped[1]:text(1) == "0", "nothing is staged through the loop")
  assert(work.close(handle))
end

--- Stages `project`, then refuses once `link` leads to `target`: the
--- refusal names the link and leaves what the first stage staged.
local function refused_above(project: string, target: string, link: string)
  local handle = assert(work.open(project))
  assert(work.stage(handle, false))
  local before = assert(Sqlite.text_rows(handle.db, "SELECT count(*) FROM files"))
  assert(before[1]:text(1) ~= "0")
  assert(Fs.symlink(target, project .. "/" .. link))
  local staged, trouble = work.stage(handle, false)
  assert(staged == nil, "a link above the root is refused")
  assert(trouble:find(link .. ": a link to ", 1, true), trouble)
  assert(trouble:find("above the root", 1, true), trouble)
  local after = assert(Sqlite.text_rows(handle.db, "SELECT count(*) FROM files"))
  assert(after[1]:text(1) == before[1]:text(1), "the refusal leaves the rows staged before")
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
  assert(rows[1]:text(1) == "Europe/Paris blob,UTC blob", rows[1]:text(1))
  assert(work.close(handle))

  local older = assert(Sqlite.memory())
  local none = assert(work.zoneinfo_of(older))
  assert(next(none) == nil)
  assert(older:close())
end

--- The web assets a boot reads from the vendored trees are hashed as they
--- are read, replace whatever the working database held, and read back
--- out of a database that has them -- and out of one without the table, as none.
local function test_web_assets_are_hashed_replaced_whole_and_read_back(tmp: string)
  for _, tree in ipairs({ { "htmx", "dist/htmx.min.js", "1.2.3", "js one" },
      { "htmx-ext-sse", "dist/sse.min.js", "4.5.6", "js two" } }) do
    assert(Fs.mkdirs(tmp .. "/vendor/" .. tree[1] .. "/dist"))
    assert(Fs.write(tmp .. "/vendor/" .. tree[1] .. "/PIN", "version " .. tree[3] .. "\nurl x\n"))
    assert(Fs.write(tmp .. "/vendor/" .. tree[1] .. "/" .. tree[2], tree[4]))
  end
  local assets = assert(work.read_web_assets(tmp .. "/vendor"))
  assert(#assets == 2 and assets[1].name == "htmx-ext-sse.min.js" and assets[2].name == "htmx.min.js")
  local first = assets[2]
  assert(first.data == "js one" and first.version == "1.2.3")
  assert(first.sha256 == Hash.hex_sha256("js one"))
  assert(first.sha384 == Codec.base64(Hash.digest("sha384", "js one")))
  local missing, trouble = work.read_web_assets(tmp .. "/nowhere")
  assert(missing == nil and trouble ~= "")

  local handle = assert(work.open(tmp))
  assert(work.put_web_assets(handle, { { name = "old.js", data = "x", sha256 = "a", sha384 = "b", version = "0" } }))
  assert(work.put_web_assets(handle, assets))
  local back = assert(work.web_assets_of(handle.db))
  assert(#back == 2 and back[1].name == "htmx-ext-sse.min.js", "an asset the tree no longer has is gone")
  assert(back[2].data == "js one" and back[2].sha384 == first.sha384 and back[2].version == "1.2.3")
  assert(work.close(handle))

  local older = assert(Sqlite.memory())
  assert(#assert(work.web_assets_of(older)) == 0)
  assert(older:close())
end

--- Stages a tree laid out as cosmic's own and answers its `boot`
--- fingerprint.
local function boot_of(root: string): string
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local fingerprint = assert(identity.record_fingerprint(handle.db, handle.root))
  assert(work.close(handle))
  return fingerprint.boot
end

--- `boot_hash` follows every module the tool carries, wherever it
--- sits: an edit to one under eval/ or test/portable, trees none of
--- the tool's C is in, moves it, and an edit to a test or testdata
--- beside them, which the tool never carries, does not. A template's
--- module is carried as a module is, so its edit moves it too.
local function test_a_carried_module_outside_the_tool_trees_moves_boot_hash(tmp: string)
  local root = tmp .. "/root"
  local files: {string:string} = {
    ["build/x.tl"] = "return {}\n",
    ["eval/summarize.tl"] = "return {}\n",
    ["test/portable/init.tl"] = "return {}\n",
    ["test/portable/tool_test.tl"] = "local function test_x() end\n",
    ["eval/testdata/case.tl"] = "return {}\n",
    ["eval/page.tmpl"] = "{{type Page from eval.summarize}}{{mode text}}one",
    ["eval/testdata/page.tmpl"] = "{{broken",
  }
  for path, data in pairs(files) do
    assert(Fs.mkdirs(root .. "/" .. path:match("^(.*)/")))
    assert(Fs.write(root .. "/" .. path, data))
  end
  local before = boot_of(root)
  assert(boot_of(root) == before, "an unchanged tree keeps its boot_hash")
  for _, path in ipairs({ "test/portable/tool_test.tl", "eval/testdata/case.tl",
      "eval/testdata/page.tmpl" }) do
    assert(Fs.write(root .. "/" .. path, "return { edited = true }\n"))
    assert(boot_of(root) == before, path .. " is not carried, and moves nothing")
  end
  for _, path in ipairs({ "eval/summarize.tl", "test/portable/init.tl", "eval/page.tmpl" }) do
    assert(Fs.write(root .. "/" .. path, "return { edited = true }\n"))
    local after = boot_of(root)
    assert(after ~= before, path .. " is carried, and moves boot_hash")
    before = after
  end
end

--- A normalized mtime does not hide an in-place rewrite from any staging
--- table, nor from the tool's cheap stale check.
local function test_settled_rewrites_with_preserved_mtime_are_read(tmp: string)
  local paths = { "probe.tl", "core/probe.c", "notes.txt", "doc/probe.md" }
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/doc"))
  for _, path in ipairs(paths) do
    assert(Fs.write(tmp .. "/" .. path, "old text\n"))
    assert(Fs.set_mtime(tmp .. "/" .. path, 0, 0))
  end
  local tracked: mut {string} = {}
  for _, path in ipairs(paths) do tracked[#tracked + 1] = tmp .. "/" .. path end
  with_change_time(tracked, function(changed: function())
    local handle = assert(work.open(tmp))
    assert(stage_settled(handle, true).read == #paths)
    assert(work.tool_moved(handle) == false)
    assert(stage_settled(handle, true).read == 0)
    for _, path in ipairs(paths) do
      local before = assert(Fs.stat(tmp .. "/" .. path))
      local fd = assert(Fs.open_write(tmp .. "/" .. path))
      assert(Fs.put(fd, "new text\n"))
      assert(Fs.close(fd))
      assert(Fs.set_mtime(tmp .. "/" .. path, 0, 0))
      local after = assert(Fs.stat(tmp .. "/" .. path))
      assert(before.ino == after.ino and before.size == after.size)
    end
    changed()
    assert(work.tool_moved(handle), "core rewrite must invalidate the tool's stat fast path")
    assert(stage_settled(handle, true).read == #paths)
    assert(staged_bytes(handle.db, "probe.tl") == "new text\n")
    for _, table_name in ipairs({ "files", "tool", "scanned", "linked" }) do
      local rows = assert(Sqlite.text_rows(handle.db, "SELECT DISTINCT sha256 FROM " .. table_name))
      assert(#rows > 0, table_name .. " must be exercised")
      for _, row in ipairs(rows) do assert(row:text(1) == Hash.hex_sha256("new text\n")) end
    end
    assert(stage_settled(handle, true).read == 0)
    assert(work.close(handle))
  end)
end

--- A ctime-only change causes a read, but the bytes alone decide the
--- build's identity. Rows migrated from a schema without ctime do too.
local function test_metadata_changes_and_unknown_change_times_keep_content_identity(tmp: string)
  local path = tmp .. "/probe.tl"
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/doc"))
  for _, name in ipairs({ "probe.tl", "core/probe.c", "notes.txt", "doc/probe.md" }) do
    assert(Fs.write(tmp .. "/" .. name, "return 1\n"))
    assert(Fs.set_mtime(tmp .. "/" .. name, 0, 0))
  end
  with_change_time({ path }, function(changed: function())
    local handle = assert(work.open(tmp))
    assert(stage_settled(handle, true).read == 4)
    local before = assert(identity.record_fingerprint(handle.db, handle.root))
    assert(sys.chmod(path, 384))
    changed()
    assert(stage_settled(handle, true).read == 1)
    local after = assert(identity.record_fingerprint(handle.db, handle.root))
    assert(before.image == after.image and before.boot == after.boot)
    assert(stage_settled(handle, true).read == 0)
    assert(work.commit(handle))
    for _, name in ipairs({ "files", "tool", "scanned", "linked" }) do
      assert(handle.db:exec("ALTER TABLE " .. name .. " DROP COLUMN ctime_ns"))
    end
    assert(handle.db:close())
    handle = assert(work.open(tmp))
    assert(staged_bytes(handle.db, "probe.tl") == "return 1\n", "migration preserves content")
    for _, name in ipairs({ "files", "tool", "scanned", "linked" }) do
      local rows = assert(Sqlite.text_rows(handle.db, "SELECT sha256, ctime_ns IS NULL FROM " .. name))
      assert(#rows > 0, name .. " migration fixture missing")
      for _, row in ipairs(rows) do
        assert(row:text(1) == Hash.hex_sha256("return 1\n") and row:text(2) == "1")
      end
    end
    assert(stage_settled(handle, true).read == 4, "legacy rows must be read once")
    assert(stage_settled(handle, true).read == 0)
    assert(work.close(handle))
  end)
end

local function test_an_unknown_change_time_never_trusts_cached_bytes(tmp: string)
  assert(Fs.write(tmp .. "/probe.tl", "return 1\n"))
  assert(Fs.set_mtime(tmp .. "/probe.tl", 0, 0))
  local handle = assert(work.open(tmp))
  local stat = Fs.stat
  Fs.stat = function(path: string): sys.Stat?, string
    local st, trouble = stat(path)
    if st ~= nil then
      local fields = st as {string:integer}
      fields["ctime_ns"] = nil
    end
    return st, trouble
  end
  local ok, trouble = pcall(function()
    assert(stage_settled(handle).read == 1)
    assert(stage_settled(handle).read == 1)
  end)
  Fs.stat = stat
  assert(work.close(handle))
  assert(ok, tostring(trouble))
end

--- Additions change discovery membership even when every known file stands.
local function test_new_tool_inputs_invalidate_read_only_freshness(tmp: string)
  local paths = { "patch/curl/new.txt", "patch/newlib/new.txt", "core/new.h",
    "eval/new.tl", "newmodules/new.tl" }
  assert(Fs.mkdirs(tmp .. "/patch/curl"))
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/eval"))
  assert(Fs.write(tmp .. "/core/old.h", "old\n"))
  local handle = assert(work.open(tmp))
  for _, path in ipairs(paths) do
    assert(stage_settled(handle, true))
    assert(work.tool_moved(handle) == false)
    local before = assert(identity.record_fingerprint(handle.db, handle.root)).boot
    assert(Fs.mkdirs(tmp .. "/" .. path:match("^(.*)/")))
    assert(Fs.write(tmp .. "/" .. path, "new\n"))
    assert(work.tool_moved(handle), path .. " must be discovered before a read-only command")
    assert(stage_settled(handle, true))
    assert(assert(identity.record_fingerprint(handle.db, handle.root)).boot ~= before)
    assert(work.tool_moved(handle) == false)
  end
  assert(work.close(handle))
end

--- Directory replacement and linked membership follow the staging walk.
local function test_tool_discovery_tracks_renames_and_link_targets(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(tmp .. "/shared"))
  assert(sys.symlink(tmp .. "/shared", root .. "/modules"))
  assert(sys.symlink(tmp .. "/later", root .. "/later"))
  local handle = assert(work.open(root))
  assert(stage_settled(handle, true))
  assert(work.tool_moved(handle), "a dangling link cannot be trusted as unchanged")
  assert(Fs.mkdirs(tmp .. "/later"))
  assert(Fs.write(tmp .. "/later/new.tl", "return {}\n"))
  assert(work.tool_moved(handle), "a new target is not invisible")
  assert(stage_settled(handle, true))
  assert(work.tool_moved(handle) == false)
  assert(Fs.write(tmp .. "/shared/new.tl", "return {}\n"))
  assert(work.tool_moved(handle), "a followed directory's membership is watched")
  assert(stage_settled(handle, true))
  assert(sys.rename(root .. "/modules", root .. "/renamed"))
  assert(work.tool_moved(handle), "renamed directories invalidate discovery")
  assert(stage_settled(handle, true))
  assert(work.tool_moved(handle) == false)
  assert(sys.rmdir(root .. "/core"))
  assert(work.tool_moved(handle), "removed empty directories invalidate discovery")
  assert(stage_settled(handle, true))
  assert(work.tool_moved(handle) == false)
  assert(work.close(handle))
end

--- Old databases and unknown metadata conservatively stage once; unchanged
--- metadata costs stats alone, with no listings or content reads.
local function test_tool_discovery_fast_path_and_unknown_metadata(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.write(tmp .. "/core/probe.h", "old\n"))
  local handle = assert(work.open(tmp))
  assert(stage_settled(handle, true))
  local walk, read = Fs.walk_following, Fs.read
  Fs.walk_following = function(): {string}?, string error("listed an unchanged tree") end
  Fs.read = function(): string?, string error("read unchanged content") end
  local ok, answer = pcall(work.tool_moved, handle)
  Fs.walk_following, Fs.read = walk, read
  assert(ok and answer == false, tostring(answer))
  assert(handle.db:exec("UPDATE tool_discovery SET ctime_ns = NULL WHERE path = 'core'"))
  assert(work.tool_moved(handle), "unknown change time must rescan")
  assert(stage_settled(handle, true))
  assert(work.tool_moved(handle) == false)
  assert(handle.db:exec("DELETE FROM tool_discovery"))
  assert(work.tool_moved(handle), "a pre-discovery database must rescan")
  assert(stage_settled(handle, true))
  assert(work.tool_moved(handle) == false)
  assert(work.close(handle))
end

--- Capturing a directory after its listing could bless a concurrent addition.
local function test_tool_discovery_does_not_bless_an_addition_after_listing(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  local handle = assert(work.open(tmp))
  local walk = Fs.walk_following
  Fs.walk_following = function(root: string, skip?: function(string, string, Fs.Kind): boolean): {string}?, string
    local files, trouble = walk(root, skip)
    assert(Fs.write(root .. "/core/late.h", "new\n"))
    return files, trouble
  end
  local ok, staged = pcall(stage_settled, handle, true)
  Fs.walk_following = walk
  assert(ok and staged ~= nil, tostring(staged))
  assert(work.tool_moved(handle), "metadata must precede the directory listing")
  assert(stage_settled(handle, true))
  assert(work.tool_moved(handle) == false)
  local before = assert(identity.record_fingerprint(handle.db, handle.root)).boot
  assert(Fs.write(tmp .. "/README.md", "prose\n"))
  assert(work.tool_moved(handle), "membership conservatively rescans")
  assert(stage_settled(handle, true))
  assert(assert(identity.record_fingerprint(handle.db, handle.root)).boot == before,
    "irrelevant additions do not move the tool's content identity")
  assert(work.tool_moved(handle) == false)
  assert(work.close(handle))
end

local function test_tool_discovery_tracks_symlink_retarget_with_equal_bytes(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root"))
  assert(Fs.mkdirs(tmp .. "/target1"))
  assert(Fs.mkdirs(tmp .. "/target2"))
  assert(Fs.write(tmp .. "/target1/a.tl", "return {}\n"))
  assert(Fs.write(tmp .. "/target2/a.tl", "return {}\n"))
  assert(sys.symlink(tmp .. "/target1", tmp .. "/root/modules"))
  local handle = assert(work.open(tmp .. "/root"))
  assert(stage_settled(handle, true))
  local before = assert(identity.record_fingerprint(handle.db, handle.root)).boot
  assert(Fs.remove(tmp .. "/root/modules"))
  assert(sys.symlink(tmp .. "/target2", tmp .. "/root/modules"))
  assert(work.tool_moved(handle), "retargeted link must rescan even with equal bytes")
  assert(stage_settled(handle, true))
  assert(assert(identity.record_fingerprint(handle.db, handle.root)).boot == before)
  assert(Fs.write(tmp .. "/root/README.md", "irrelevant\n"))
  assert(work.tool_moved(handle))
  assert(stage_settled(handle, true))
  assert(assert(identity.record_fingerprint(handle.db, handle.root)).boot == before)
  assert(work.tool_moved(handle) == false)
  assert(work.close(handle))
end

--- Stages a project of just `files` (path to bytes) and answers the
--- stage's result and trouble.
local function stage_files(root: string, files: {string:string}): work.Staged?, string
  for path, data in pairs(files) do
    local slash = path:match("^(.*)/[^/]*$")
    if slash ~= nil then assert(Fs.mkdirs(root .. "/" .. slash)) end
    assert(Fs.write(root .. "/" .. path, data))
  end
  local handle = assert(work.open(root))
  local staged, trouble = work.stage(handle, false)
  assert(work.close(handle))
  if staged ~= nil then return staged end
  return nil, trouble
end

--- A file under `static/` is an input whatever it is called: Teal, a
--- template and bytes with a NUL are rows of `files` (the build later
--- makes assets of them, not modules), a hidden one is left out, and a
--- TODO in one is not the project's.
local function test_stage_takes_every_file_under_static(tmp: string)
  assert(stage_files(tmp, {
    ["static/css/app.css"] = "a{}", ["static/notes.tl"] = "TODO: not ours\nx", ["static/p.tmpl"] = "{{",
    ["static/bin.dat"] = "\0\1\2", ["static/.hidden/x"] = "x", ["main.tl"] = "return 1\n",
  }))
  local db = assert(Sqlite.open(build_dir(tmp) .. "/build.db"))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT path FROM files WHERE path GLOB 'static/*' ORDER BY path"))
  local paths: mut {string} = {}
  for i, row in ipairs(rows) do paths[i] = row:text(1) end
  assert(table.concat(paths, " ") == "static/bin.dat static/css/app.css static/notes.tl static/p.tmpl",
    table.concat(paths, " "))
  assert(count(db, "todos") == 0, "a TODO inside an asset is no TODO of the project's")
  assert(db:close())
end

--- A `.tl` or `.tmpl` under `static/` is no module: staging says so, one
--- line naming the file, when it reads the file; other assets earn none.
local function test_stage_notes_a_module_shaped_asset(tmp: string)
  local staged = assert(stage_files(tmp, { ["static/notes.tl"] = "x", ["static/p.tmpl"] = "{{",
    ["static/a.css"] = "a{}", ["main.tl"] = "return 1\n" }))
  table.sort(staged.notes)
  assert(#staged.notes == 2, table.concat(staged.notes, "\n"))
  assert(staged.notes[1]:find("^static/notes%.tl: ") and staged.notes[2]:find("^static/p%.tmpl: "))
end

--- Each rule the build refuses an asset by, named by the file.
local function test_stage_refuses_an_asset_it_cannot_carry(tmp: string)
  local cases: {{string}} = {
    { "static/a%b.css", "x", "rename it" },
    { "static/a?b.css", "x", "rename it" },
    { "static/a#b.css", "x", "rename it" },
    { "static/a\\b.css", "x", "rename it" },
    { "static/a\1b.css", "x", "control byte" },
    { "static/" .. ("n"):rep(100) .. "/" .. ("n"):rep(100) .. "/" .. ("n"):rep(56), "x",
      "past the 255-byte limit" },
    { "static/big.bin", ("x"):rep(16 * 1024 * 1024 + 1), "past the 16 MiB limit" },
  }
  for i, case in ipairs(cases) do
    local staged, trouble = stage_files(tmp .. "/" .. i, { [case[1]] = case[2] })
    assert(staged == nil, case[1])
    assert(trouble:find(case[1], 1, true) and trouble:find(case[3], 1, true), trouble)
  end
  local fine = stage_files(tmp .. "/fine", { ["static/" .. ("n"):rep(100) .. "/" .. ("n"):rep(100) .. "/" .. ("n"):rep(53)] = "x",
    ["static/16.bin"] = ("x"):rep(16 * 1024 * 1024) })
  assert(fine ~= nil, "255 bytes and 16 MiB are within the limits")
end

--- Names that differ only in case would be two files here and one on a
--- case-insensitive disk.
local function test_stage_refuses_assets_that_differ_only_in_case(tmp: string)
  -- A file system that folds case (macOS's, by default) holds the two
  -- names as one file, so there is no pair to refuse.
  assert(Fs.mkdirs(tmp .. "/probe"))
  assert(Fs.write(tmp .. "/probe/A", "a"))
  assert(Fs.write(tmp .. "/probe/a", "b"))
  if #assert(Fs.list(tmp .. "/probe")) < 2 then
    Test.skip("this file system folds case, so two names that differ only in case are one file")
  end
  local staged, trouble = stage_files(tmp, { ["static/App.css"] = "a", ["static/app.css"] = "b" })
  assert(staged == nil and trouble:find("only in case", 1, true), tostring(trouble))
  assert(trouble:find("static/App.css", 1, true) and trouble:find("static/app.css", 1, true))
end

--- A link inside the project is followed; one that leaves it would make
--- the executable depend on a file the checkout lacks.
local function test_stage_refuses_an_asset_linked_from_outside_the_project(tmp: string)
  assert(Fs.mkdirs(tmp .. "/outside"))
  assert(Fs.write(tmp .. "/outside/secret.txt", "SECRET"))
  assert(Fs.mkdirs(tmp .. "/p/static"))
  assert(Fs.mkdirs(tmp .. "/p/shared"))
  assert(Fs.write(tmp .. "/p/shared/ok.txt", "fine"))
  assert(Fs.symlink("../shared/ok.txt", tmp .. "/p/static/inside.txt"))
  assert(stage_files(tmp .. "/p", { ["main.tl"] = "return 1\n" }), "a link within the project stages")
  assert(Fs.symlink("../../outside/secret.txt", tmp .. "/p/static/leak.txt"))
  local staged, trouble = stage_files(tmp .. "/p", { ["main.tl"] = "return 1\n" })
  assert(staged == nil and trouble:find("static/leak.txt: a link to ", 1, true), tostring(trouble))
  assert(trouble:find("outside the project", 1, true))
  assert(Fs.remove(tmp .. "/p/static/leak.txt"))
  assert(Fs.symlink("../../outside", tmp .. "/p/static/dir"))
  local through, through_trouble = stage_files(tmp .. "/p", { ["main.tl"] = "return 1\n" })
  assert(through == nil and through_trouble:find("static/dir/secret.txt", 1, true), tostring(through_trouble))
end

local function test_identity_knows_a_static_asset_by_its_directory(_tmp: string)
  assert(identity.is_static("static/a.tl") and identity.is_static("static/x/y.css"))
  assert(not identity.is_static("static") and not identity.is_static("a/static/x.css"))
  assert(not identity.is_static("statics/x.css") and not identity.is_static("static.tl"))
  assert(identity.is_input("static/a.css", false) and identity.is_input("static/a.png", true))
  assert(not identity.is_tool("static/a.tl", true), "an asset is not part of the tool")
end

--- A stage records the code that staged it, which this code takes for
--- its own; a database that records another code, or none, it takes for
--- another's ([`work.other_code`]).
local function test_a_stage_records_the_code_that_staged_it(tmp: string)
  local handle = assert(work.open(tmp))
  local before, before_trouble = work.other_code(handle.db)
  assert(before == "", "a database no stage wrote is taken for this code's: " ..
      tostring(before) .. before_trouble)
  stage_settled(handle)
  local rows = assert(Sqlite.text_rows(handle.db, "SELECT value FROM meta WHERE key = 'staged_by'"))
  assert(#rows == 1, "the stage recorded no code")
  local own, own_trouble = work.other_code(handle.db)
  assert(own == nil and own_trouble == "", "this code's stage is taken for another's: " .. tostring(own))
  assert(Sqlite.run(handle.db, "UPDATE meta SET value = 'another' WHERE key = 'staged_by'"))
  local other, _ = work.other_code(handle.db)
  assert(other == "another", tostring(other))
  assert(work.close(handle))
end

--- The seed's files are in the image: a boot compiles the compiler the tool carries from them alone, so an edit to one of
--- them is a tool a rebuild by the running tool cannot make. A file of the tool the seed does not list moves only `boot`.
local function test_an_edit_to_a_file_the_seed_lists_moves_the_image(tmp: string)
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.mkdirs(tmp .. "/lang"))
  assert(Fs.mkdirs(tmp .. "/cosmic"))
  assert(Fs.write(tmp .. "/build/seed.txt", "lang/check.tl\n"))
  assert(Fs.write(tmp .. "/lang/check.tl", "return 1\n"))
  assert(Fs.write(tmp .. "/cosmic/other.tl", "return 1\n"))
  local handle = assert(work.open(tmp))
  stage_settled(handle, true)
  local before = assert(identity.record_fingerprint(handle.db, handle.root))
  assert(Fs.write(tmp .. "/cosmic/other.tl", "return 2\n"))
  stage_settled(handle, true)
  local unlisted = assert(identity.record_fingerprint(handle.db, handle.root))
  assert(unlisted.boot ~= before.boot and unlisted.image == before.image, "a file the seed does not list moved the image")
  assert(Fs.write(tmp .. "/lang/check.tl", "return 2\n"))
  stage_settled(handle, true)
  local listed = assert(identity.record_fingerprint(handle.db, handle.root))
  assert(listed.image ~= unlisted.image, "an edit to a file the seed lists left the image as it was")
  assert(work.close(handle))
end
