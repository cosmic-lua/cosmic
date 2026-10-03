local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local artifact = require("build.artifact")
local fixture = require("build.sql_artifact_fixture")

local function value(db: Sqlite.Handle, schema?: string): string
  local rows = assert(Sqlite.text_rows(db, "SELECT source FROM " .. (schema or "main") .. ".modules"))
  return rows[1][1]
end

local function test_foreign_host_and_portable_databases_join_without_loading_modules(tmp: string)
  local a = assert(Sqlite.artifact(fixture.write(tmp, "a", "one", true)))
  local b = assert(Sqlite.artifact(fixture.write(tmp, "b", "two")))
  local db = assert(a:open())
  assert(db:attach_artifact(b, "other"))
  assert(a:close())
  assert(b:close())
  local rows = assert(Sqlite.text_rows(db, "SELECT a.source,b.source FROM main.modules a JOIN other.modules b USING(path)"))
  assert(rows[1][1] == "one" and rows[1][2] == "two")
  assert(db:close())
end

local function test_two_handles_and_statements_keep_their_own_references(tmp: string)
  local path = fixture.write(tmp, "a", "one")
  local a = assert(Sqlite.artifact(path))
  local b = assert(Sqlite.artifact(path))
  local db = assert(a:open())
  local other = assert(b:open())
  assert(db:attach_artifact(b, "again"))
  assert(a:close())
  assert(a:close())
  assert(not pcall(function() a:open() end))
  b = nil
  collectgarbage("collect")
  assert(value(other) == "one" and value(db, "again") == "one")
  local statement = assert(db:prepare("SELECT source FROM again.modules"))
  assert(statement:step() == "row")
  assert(not db:close(), "close with a live statement must remain usable")
  assert(not db:exec("DETACH again"), "an active attachment must stay alive")
  statement:finalize()
  assert(db:exec("DETACH again"))
  assert(other:close())
  assert(value(db) == "one")
  assert(db:close())
end

local function test_path_replacement_and_unlink_do_not_redirect_reads(tmp: string)
  local path = fixture.write(tmp, "a", "old", true)
  local a = assert(Sqlite.artifact(path))
  assert(sys.rename(path, path .. ".retained"))
  local replacement = fixture.write(tmp, "replacement", "new")
  assert(sys.rename(replacement, path))
  assert(sys.unlink(path .. ".retained"))
  local db = assert(a:open())
  assert(a:close())
  assert(value(db) == "old")
  assert(db:close())
  local b = assert(Sqlite.artifact(path))
  local replaced = assert(b:open())
  assert(value(replaced) == "new")
  assert(replaced:close())
  assert(b:close())
end

local function test_inspection_is_read_only_and_attachment_capability_is_explicit(tmp: string)
  local path = fixture.write(tmp, "a", "one")
  local a = assert(Sqlite.artifact(path))
  local db = assert(a:open())
  for _, sql in ipairs({ "DELETE FROM modules", "CREATE TABLE x(v)", "PRAGMA user_version=8",
      "PRAGMA writable_schema=ON", "PRAGMA query_only=OFF", "VACUUM INTO 'new.db'",
      "ATTACH ':memory:' AS raw", "ATTACH '" .. path .. ".db' AS raw" }) do
    assert(not db:exec(sql), sql .. " was allowed")
  end
  assert(assert(Sqlite.text_rows(db, "PRAGMA user_version"))[1][1] == "7")
  assert(#assert(Sqlite.text_rows(db, "PRAGMA table_info(modules)")) == 2)
  assert(assert(Sqlite.text_rows(db, "PRAGMA integrity_check"))[1][1] == "ok")
  assert(assert(Sqlite.text_rows(db, "SELECT body FROM docs WHERE docs MATCH 'searchable'"))[1][1] == "searchable")
  assert(#assert(Sqlite.text_rows(db, "SELECT * FROM pragma_table_info('modules')")) == 2)
  assert(assert(Sqlite.text_rows(db, "SELECT source FROM harmless"))[1][1] == "one")
  assert(not db:exec("SELECT * FROM hostile"), "schema invoked a DIRECTONLY function")
  assert(assert(Sqlite.text_rows(db, "SELECT length(sha256('safe')),inflate(deflate('safe'))"))[1][2] == "safe")
  local ordinary = assert(Sqlite.memory())
  assert(not pcall(function() ordinary:attach_artifact(a, "no") end))
  assert(ordinary:exec("ATTACH '" .. path .. ".db' AS plain"))
  assert(value(ordinary, "plain") == "one")
  assert(ordinary:close())
  assert(db:attach_artifact(a, "quoted\"schema"))
  assert(not db:attach_artifact(a, "quoted\"schema"))
  local _ = db:limit("attached", 1)
  assert(not db:attach_artifact(a, "over_limit"))
  assert(not pcall(function() db:attach_artifact(a, "bad\0name") end))
  local _ = db:limit("attached", 10)
  assert(db:attach_artifact(a, "after_failure"))
  assert(value(db, "after_failure") == "one")
  assert(db:close())
  assert(a:close())
end

local function test_metadata_names_and_vfs_uris_cannot_be_replayed(tmp: string)
  local a = assert(Sqlite.artifact(fixture.write(tmp, "a", "one")))
  local db = assert(a:open())
  local filename = assert(Sqlite.text_rows(db, "PRAGMA database_list"))[1][3]
  local plain = fixture.write(tmp, "plain", "two", true) .. ".db"
  local ordinary = assert(Sqlite.open(plain, { immutable = true }))
  for _ = 1, 2 do
    for _, suffix in ipairs({ "", "&off=0&len=4096" }) do
      assert(not ordinary:exec("ATTACH 'file:" .. filename .. "?vfs=cosmic-inspection&mode=ro&immutable=1" .. suffix .. "' AS replay"))
    end
  end
  assert(db:close())
  assert(a:close())
  assert(not ordinary:exec("ATTACH 'file:" .. filename .. "?vfs=cosmic-inspection&mode=ro' AS replay"))
  assert(ordinary:close())
end

local function test_bad_paths_and_nonregular_inputs_are_refused(tmp: string)
  local path = fixture.write(tmp, "a", "one")
  assert(Sqlite.artifact(path .. "\0suffix") == nil)
  assert(Sqlite.artifact(tmp) == nil)
  assert(Sqlite.artifact(path .. ".missing") == nil)
  assert(sys.mkfifo(tmp .. "/fifo", 384))
  assert(Sqlite.artifact(tmp .. "/fifo") == nil)
  local bytes = assert(Fs.read(path))
  for index, broken in ipairs({ "", "not an artifact", bytes:sub(1, -2), bytes .. "x",
      bytes:sub(1, -9) .. string.pack(">i8", -1) }) do
    local bad = tmp .. "/bad" .. index
    assert(Fs.write(bad, broken))
    assert(Sqlite.artifact(bad) == nil, "bad range was accepted")
  end
end

local function test_a_failed_sqlite_attachment_leaves_the_next_permit_usable(tmp: string)
  local good = fixture.write(tmp, "good", "one")
  local parts = assert(artifact.split((assert(Fs.read(good)))))
  local bad = tmp .. "/bad-sqlite"
  local database = parts.database:sub(1, 16) .. "\0\0" .. parts.database:sub(19)
  assert(Fs.write(bad, (assert(artifact.rejoin(parts, database)))))
  local a = assert(Sqlite.artifact(good))
  local broken = assert(Sqlite.artifact(bad))
  local db = assert(a:open())
  assert(not db:attach_artifact(broken, "bad"))
  assert(db:attach_artifact(a, "good"))
  assert(value(db, "good") == "one")
  assert(broken:close())
  assert(a:close())
  assert(db:close())
end

local function test_captured_outcomes_preserve_inspection_authorization(tmp: string)
  local a = assert(Sqlite.artifact(fixture.write(tmp, "a", "one")))
  local db = assert(a:open())
  assert(db:attach_artifact(a, "other"))
  assert(a:close())
  local prepared = db:prepare_result("SELECT source FROM other.modules WHERE path=?1")
  assert(prepared.code == Sqlite.OK and prepared.statement ~= nil)
  local statement = prepared.statement
  assert(statement:bind_values_result({ { text = "fixture.module" } }).code == Sqlite.OK)
  assert(statement:step_result() == "row")
  assert(statement:bytes(0) == "one")
  assert(statement:step_result() == "done")
  statement:finalize()
  for _, sql in ipairs({ "DELETE FROM modules", "ATTACH ':memory:' AS raw" }) do
    local executed = db:exec_result(sql)
    local run = Sqlite.run_result(db, sql)
    assert(executed.code == 23 and executed.extended_code == 23)
    assert(run.code == executed.code and run.reason ~= "" and not run.cancelled)
    local rows = Sqlite.text_rows_result(db, "SELECT source FROM other.modules")
    assert(rows.code == Sqlite.OK and rows.rows[1][1] == "one")
  end
  local rows = Sqlite.rows_result(db, "SELECT source FROM modules")
  assert(rows.code == Sqlite.OK and rows.rows[1][1].text == "one")
  assert(db:close())
end
