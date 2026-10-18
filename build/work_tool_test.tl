--- [`build.work`]'s test that starts the program beside this process: a
--- second build of a tree one holds. Apart from build/work_test.tl's so those
--- stand while the tree moves; `cosmic test` in a project reached through
--- links is in build/work_nested_tool_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local build_paths = require("build.paths")
local rebuild_lock = require("build.rebuild_lock")
local this_program = require("build.this_program")
local work = require("build.work")
local Test = require("cosmic.test")

--- The program itself, which its test starts.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
}

--- A second process building the same tree waits for the first's
--- transaction instead of failing with "database is locked": two builds
--- of one tree at once, from two terminals or two parallel tests, both
--- finish.
local function test_a_second_build_of_a_tree_waits_for_the_first(tmp: string)
  assert(Fs.write(tmp .. "/main.tl", "return function(): integer return 0 end\n"))
  local held = assert(work.open(tmp))
  local output = tmp .. "/second.out"
  local fd = assert(Fs.open_write(output))
  local build = this_program.program({ "main.tl" },
    { cwd = tmp, stdout = fd, stderr = fd })
  local second, trouble = Child.start(build.argv, build.options)
  assert(Fs.close(fd))
  assert(second, trouble)
  assert(Clock.sleep_ns(300000000))
  assert(work.abort(held))
  local result = assert(second:wait(Clock.seconds(60)))
  assert(result.ok, "the second build failed: " .. (Fs.read(output) or ""))
end

--- The working database of `tmp`, made and then stamped with another
--- schema, as another tool's would be: its path.
local function of_another_schema(tmp: string): string
  local made = assert(work.open(tmp))
  assert(Sqlite.run(made.db, "UPDATE meta SET value = 'another' WHERE key = 'schema'"))
  local path = made.dir .. "/build.db"
  assert(work.close(made))
  return path
end

--- A build of `tmp` started beside this process running `script`, once
--- it has said that it waits for another run's lock, which it says once
--- it has waited a second; and what it said on stderr until then, or till
--- it ended.
local function waiting(tmp: string, script: string): Child.Handle, string
  local started = this_program.program({ "-e", script }, { cwd = tmp,
    stdout = "capture", stderr = "stream", timeout_ns = Clock.seconds(60) })
  local child = assert(Child.start(started.argv, started.options))
  local said = ""
  local stderr = assert(child.stderr_stream)
  while not said:find("waiting for it", 1, true) do
    local chunk = stderr:read()
    if chunk == nil or chunk == "" then break end
    said = said .. chunk
  end
  return child, said
end

--- A build that finds the working database of another schema waits for
--- the run that holds its write lock, as a newer tool building in it
--- would, before it removes the file, and then makes it again of its own.
local function test_a_build_waits_for_the_lock_before_removing_a_file_of_another_schema(tmp: string)
  local path = of_another_schema(tmp)
  local before = assert(Fs.stat(path)).ino
  local held = assert(Sqlite.open(path, { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local child, said = waiting(tmp, 'local work = require("build.work"); ' ..
      'local Sqlite = require("cosmic.sqlite"); local Fs = require("cosmic.fs"); ' ..
      'local handle = assert(work.open(' .. string.format("%q", tmp) .. ')); ' ..
      'local rows = assert(Sqlite.text_rows(handle.db, "SELECT value FROM meta WHERE key = \'schema\'")); ' ..
      'assert(Fs.put(1, rows[1]:text(1))); assert(work.close(handle))')
  local during = Fs.stat(path)
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  local result = assert(child:wait(Clock.seconds(60)))
  assert(said:find("waiting for it", 1, true), "the build did not wait for the lock: " .. said)
  assert(during ~= nil and during.ino == before, "the file was removed under the lock: " .. said)
  local schema = result.stdout or ""
  assert(result.ok, said .. schema)
  assert(schema ~= "" and schema ~= "another", "the file of another schema was kept: " .. schema)
  -- By its schema, not its inode, which a file made at once after the
  -- old one is removed may be given again.
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'schema'"))
  assert(db:close())
  assert(assert(rows[1]):text(1) == schema, "the file was not made again")
end

--- Two builds that both wait for the lock on a file of another schema
--- remove it once between them: the second to take it finds the file
--- at the path made again by the first, and opens that instead of
--- removing it in turn.
local function test_two_builds_waiting_on_a_file_of_another_schema_remove_it_once(tmp: string)
  local path = of_another_schema(tmp)
  local held = assert(Sqlite.open(path, { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local script = 'local work = require("build.work"); ' ..
    'assert(work.close((assert(work.open(' .. string.format("%q", tmp) .. ')))))'
  local first, first_said = waiting(tmp, script)
  local second, second_said = waiting(tmp, script)
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  local first_result = assert(first:wait(Clock.seconds(60)))
  local second_result = assert(second:wait(Clock.seconds(60)))
  for _, said in ipairs({ first_said, second_said }) do
    assert(said:find("waiting for it", 1, true), "a build did not wait: " .. said)
  end
  assert(first_result.ok, first_said .. (first_result.stderr or ""))
  assert(second_result.ok, second_said .. (second_result.stderr or ""))
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'run'"))
  assert(db:close())
  local runs = assert(rows[1]):text(1)
  assert(runs == "2", "the file the first build made was removed: its runs are " .. runs)
end

--- A script that opens `tmp`'s working database as a build does, and
--- prints the schema the file at its path records once the build has
--- closed it, or "gone" where there is none.
local function opening_script(tmp: string): string
  return 'local work = require("build.work"); local Sqlite = require("cosmic.sqlite"); ' ..
    'local Fs = require("cosmic.fs"); ' ..
    'local handle = assert(work.open(' .. string.format("%q", tmp) .. ')); ' ..
    'local path = handle.dir .. "/build.db"; assert(work.close(handle)); ' ..
    'if not Fs.exists(path) then assert(Fs.put(1, "gone")) return end; ' ..
    'local db = assert(Sqlite.open(path)); ' ..
    'local rows = assert(Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = \'schema\'")); ' ..
    'assert(db:close()); assert(Fs.put(1, rows[1]:text(1)))'
end

--- A build granted the write lock on a file another run removed while it
--- waited opens the file at the path anew: building in the removed one,
--- unlinked, it would lose its run and still pass.
local function test_a_build_granted_the_lock_on_a_removed_file_opens_the_path_anew(tmp: string)
  local made = assert(work.open(tmp))
  local path = made.dir .. "/build.db"
  assert(work.close(made))
  local held = assert(Sqlite.open(path, { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local child, said = waiting(tmp, opening_script(tmp))
  assert(Fs.remove(path))
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  local result = assert(child:wait(Clock.seconds(60)))
  assert(said:find("waiting for it", 1, true), "the build did not wait for the lock: " .. said)
  local schema = result.stdout or ""
  assert(result.ok, said .. schema)
  assert(schema ~= "gone", "the build ran in the removed file")
end

--- A build that waits for the lock on a fresh file another tool is
--- making and stamping with its own schema finds that schema once the
--- lock is granted, and makes the file again: its own stamp, which keeps
--- a schema there is, would otherwise leave it building under another's.
local function test_a_build_makes_again_a_fresh_file_another_tool_stamped_while_it_waited(tmp: string)
  local path = build_paths.under((assert(build_paths.prepare(tmp)))).working
  local other = assert(Sqlite.open(path, { writable = true }))
  assert(Sqlite.text_rows(other, "PRAGMA journal_mode = WAL"))
  assert(other:exec("BEGIN IMMEDIATE"))
  assert(other:exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID"))
  assert(other:exec("INSERT INTO meta (key, value) VALUES ('schema', 'another')"))
  local child, said = waiting(tmp, opening_script(tmp))
  assert(other:exec("COMMIT"))
  assert(other:close())
  local result = assert(child:wait(Clock.seconds(60)))
  assert(said:find("waiting for it", 1, true), "the build did not wait for the lock: " .. said)
  local schema = result.stdout or ""
  assert(result.ok, said .. schema)
  assert(schema ~= "" and schema ~= "another" and schema ~= "gone",
    "the build kept another tool's schema: " .. schema)
end

--- A build that finds the working database of another schema waits for
--- the run that holds the checkout's rebuild lock before it removes the
--- file: that run, a `cosmic test`, keeps a handle on it between its own
--- transactions, while its write lock is free.
local function test_a_build_waits_for_the_rebuild_lock_before_removing_a_file_of_another_schema(tmp: string)
  local path = of_another_schema(tmp)
  local before = assert(Fs.stat(path)).ino
  -- Held here as a `cosmic test` run holds it.
  assert(rebuild_lock.take(tmp, 0, "test") == "held")
  local child, said = waiting(tmp, opening_script(tmp))
  local during = Fs.stat(path)
  rebuild_lock.release()
  local result = assert(child:wait(Clock.seconds(60)))
  assert(said:find("waiting for it", 1, true), "the build did not wait for the rebuild lock: " .. said)
  assert(during ~= nil and during.ino == before, "the file was removed under the rebuild lock: " .. said)
  local schema = result.stdout or ""
  assert(result.ok, said .. schema)
  assert(schema ~= "another" and schema ~= "gone", "the file was not made again: " .. schema)
end

--- A build that waits for the write lock to put a file in write-ahead
--- mode, and is granted it on a file another run put in place of the
--- one it opened, opens the path anew: its run, built in the file it
--- opened, would go to a file no longer there, and the run count of the
--- one at the path stay as it was.
local function test_a_build_whose_file_is_replaced_while_it_waits_to_log_opens_the_path_anew(tmp: string)
  local made = assert(work.open(tmp))
  local path = made.dir .. "/build.db"
  assert(work.close(made))
  -- In rollback mode, which a build switches out of under the write lock.
  local rollback = assert(Sqlite.open(path, { writable = true }))
  local mode = assert(Sqlite.text_rows(rollback, "PRAGMA journal_mode = DELETE"))
  assert(assert(mode[1]):text(1) == "delete")
  assert(rollback:close())
  local bytes = assert(Fs.read(path))
  local held = assert(Sqlite.open(path, { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local child, said = waiting(tmp, 'local work = require("build.work"); ' ..
      'local Sqlite = require("cosmic.sqlite"); local Fs = require("cosmic.fs"); ' ..
      'local handle = assert(work.open(' .. string.format("%q", tmp) .. ')); ' ..
      'local path = handle.dir .. "/build.db"; assert(work.close(handle)); ' ..
      'local db = assert(Sqlite.open(path)); ' ..
      'local rows = assert(Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = \'run\'")); ' ..
      'assert(db:close()); assert(Fs.put(1, rows[1]:text(1)))')
  -- Another file, at another inode, at the path.
  assert(Fs.remove(path))
  assert(Fs.write(path, bytes))
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  local stderr = assert(child.stderr_stream)
  while true do
    local chunk = stderr:read()
    if chunk == nil or chunk == "" then break end
    said = said .. chunk
  end
  local result = assert(child:wait(Clock.seconds(60)))
  assert(said:find("waiting for it", 1, true), "the build did not wait for the lock: " .. said)
  local runs = result.stdout or ""
  assert(result.ok, said .. runs)
  assert(runs == "2", "the build ran in the file it opened, not the one at the path: its runs are " .. runs)
end

--- A warmed compiled source cannot hide a rewrite behind a normalized mtime.
local function test_a_settled_source_rewrite_runs_new_bytecode(tmp: string)
  local path = tmp .. "/main.tl"
  assert(Fs.write(path, 'print("OLD")\n'))
  assert(Fs.set_mtime(path, 0, 0))
  local function run(): string
    local started = this_program.program({ "main.tl" }, { cwd = tmp,
      env = this_program.environment(), stdout = "capture", stderr = "capture",
      timeout_ns = Clock.seconds(60) })
    local result = assert(Child.run(started.argv, started.options))
    assert(result.ok, (result.stdout or "") .. (result.stderr or ""))
    return result.stdout
  end
  assert(run() == "OLD\n")
  local handle = assert(work.open(tmp))
  local now = Clock.now_ns
  Clock.now_ns = function(): integer return now() + Clock.seconds(3) end
  local ok, staged, trouble = pcall(work.stage, handle, false)
  Clock.now_ns = now
  assert(ok and staged ~= nil, tostring(trouble))
  assert(work.close(handle))
  assert(run() == "OLD\n")
  local before = assert(Fs.stat(path))
  local fd = assert(Fs.open_write(path))
  assert(Fs.put(fd, 'print("NEW")\n'))
  assert(Fs.close(fd))
  assert(Fs.set_mtime(path, 0, 0))
  local after = assert(Fs.stat(path))
  assert(after.size == before.size and after.ino == before.ino)
  assert(run() == "NEW\n", "the preserved mtime must not reuse OLD bytecode")
end
