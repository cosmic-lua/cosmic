--- Real SQLite caches exercise retention, save identities and conservative failures.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local cache = require("build.cache")
local formats = require("build.cache_formats")
local maintenance = require("build.cache_maintenance")

local function database(path: string, schema: {string}): Sqlite.Handle
  local db = assert(Sqlite.open(path, { writable = true }))
  for _, sql in ipairs(schema) do assert(db:exec(sql)) end
  return db
end

local function compiled(db: Sqlite.Handle, key: string, stamp: integer)
  assert(Sqlite.run(db, "INSERT INTO compiled_v2 VALUES (?1, x'00ff', x'61', x'', 'digest', 2, ?2)",
    { { text = key }, { integer = stamp } }))
end

local function trim(path: string, family: maintenance.Family, since?: integer,
    restored?: string): maintenance.Result
  return maintenance.run({ family = family, paths = { path }, since_ns = since,
    whole = since == nil, restored = restored })
end

local function count(path: string, name: string): integer
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.rows(db, "SELECT count(*) FROM " .. name))
  assert(db:close())
  return rows[1][1].integer
end

local function test_compiles_trim_even_when_no_row_was_reached(tmp: string)
  local path = tmp .. "/cache.db"
  local db = database(path, formats.compiles)
  compiled(db, "old", 4)
  assert(db:exec("INSERT INTO parsed_v1 VALUES ('a','s',0,'',x'','d',0,4)"))
  assert(db:close())
  local result = trim(path, "compiles", 5)
  assert(result.complete, result.report.files[1].reason)
  local file = result.report.files[1]
  assert(file.kept == 0 and file.removed == 2 and not file.reached)
  assert(count(path, "compiled_v2") == 0 and count(path, "parsed_v1") == 0)
end

local function test_equal_cutoff_is_kept_and_fresh_counts_only_compiles(tmp: string)
  local path, old = tmp .. "/cache.db", tmp .. "/snapshot.db"
  local db = database(path, formats.compiles)
  compiled(db, "old", 4); compiled(db, "equal", 5); compiled(db, "new", 6)
  assert(db:exec("INSERT INTO parsed_v1 VALUES ('a','s',0,'',x'','d',0,5)"))
  assert(db:close())
  db = database(old, formats.compiles); compiled(db, "equal", 1); assert(db:close())
  local result = trim(path, "compiles", 5, old)
  assert(result.complete, table.concat(result.report.warnings, ";"))
  assert(result.report.files[1].kept == 3 and result.report.files[1].removed == 1)
  assert(result.report.fresh == 1)
  assert(count(old, "compiled_v2") == 1, "the snapshot belongs to the caller")
  local absent = trim(path, "compiles", 5, tmp .. "/absent.db")
  assert(absent.complete and absent.report.fresh == 2)
  assert(Fs.stat(tmp .. "/absent.db") == nil)
end

local function test_verdicts_keep_unreached_then_trim_all_supported_tables(tmp: string)
  local path = tmp .. "/verdicts.db"
  local db = database(path, formats.verdicts)
  assert(db:exec(formats.legacy_verdicts))
  assert(db:exec("INSERT INTO declared_v1 VALUES ('d','test',x'',0,1,'origin','')"))
  assert(db:exec("INSERT INTO stores_v1 VALUES ('address','digest',1)"))
  assert(db:exec("INSERT INTO verdicts_v4 VALUES ('v','test','m',x'',x'',0,1,'origin')"))
  assert(db:close())
  local untouched = trim(path, "verdicts", 5)
  assert(untouched.complete and untouched.report.files[1].kept == 3 and
    untouched.report.files[1].removed == 0 and not untouched.report.files[1].reached)
  db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("INSERT INTO stores_v1 VALUES ('new','digest',5)")); assert(db:close())
  local cut = trim(path, "verdicts", 5)
  assert(cut.complete and cut.report.files[1].kept == 1 and cut.report.files[1].removed == 3)
end

local function test_whole_verdicts_never_vacuum_or_delete_active_rows(tmp: string)
  local path = tmp .. "/verdicts.db"
  local db = database(path, formats.verdicts)
  assert(db:exec("INSERT INTO stores_v1 VALUES ('address','digest',1)")); assert(db:close())
  local before = assert(Fs.read(path))
  local result = trim(path, "verdicts")
  assert(result.complete and result.report.files[1].kept == 1)
  assert(result.report.files[1].removed == 0 and result.report.files[1].reached == nil)
  assert(Fs.read(path) == before)
end

local function test_future_shapes_and_constraints_remain_whole(tmp: string)
  local path = tmp .. "/cache.db"
  local db = database(path, {})
  assert(db:exec("CREATE TABLE compiled_v2 (key TEXT PRIMARY KEY, used_ns INTEGER)"))
  assert(db:exec("INSERT INTO compiled_v2 VALUES ('old', 1)"))
  assert(db:exec("CREATE TABLE compiled_v99 (key TEXT, used_ns INTEGER)"))
  assert(db:exec("INSERT INTO compiled_v99 VALUES ('future', 1)"))
  assert(db:exec("CREATE TABLE parsed_v99 (value TEXT)"))
  assert(db:exec("INSERT INTO parsed_v99 VALUES ('unversioned')")); assert(db:close())
  local result = trim(path, "compiles", 5)
  assert(result.complete and result.report.files[1].kept == 3 and result.report.files[1].removed == 0)
  assert(#result.report.files[1].unknown_tables == 3 and #result.report.files[1].unstamped_tables == 1)
  assert(result.report.digest ~= nil)
  local compared = trim(path, "compiles", 5, tmp .. "/missing")
  assert(not compared.complete and compared.report.fresh == nil and #compared.report.warnings == 1)
end

local function test_trigger_cannot_delete_unrelated_data(tmp: string)
  local path = tmp .. "/cache.db"
  local db = database(path, formats.compiles); compiled(db, "old", 1)
  assert(db:exec("CREATE TABLE unrelated (value TEXT); INSERT INTO unrelated VALUES ('keep')"))
  assert(db:exec("CREATE TRIGGER surprising AFTER DELETE ON compiled_v2 BEGIN DELETE FROM unrelated; END"))
  assert(db:close())
  local result = trim(path, "compiles", 5)
  assert(result.complete and result.report.files[1].removed == 0)
  assert(count(path, "compiled_v2") == 1 and count(path, "unrelated") == 1)
end

local function test_missing_and_unreadable_active_files_are_never_created_or_removed(tmp: string)
  local missing = tmp .. "/missing/absent.db"
  local result = trim(missing, "compiles", 5)
  assert(result.complete and result.report.files[1].state == "missing" and result.report.digest == nil)
  assert(Fs.stat(tmp .. "/missing") == nil)
  local path = tmp .. "/cache.db"
  assert(Fs.write(path, "not a SQLite database"))
  result = trim(path, "compiles", 5)
  assert(not result.complete and result.report.files[1].state == "failed" and result.report.digest == nil)
  assert(Fs.read(path) == "not a SQLite database")
end

local function test_only_exact_retired_basename_siblings_are_removed(tmp: string)
  local path = tmp .. "/cache.db"
  assert(Fs.write(path .. ".corrupt-1", "retired"))
  assert(Fs.write(tmp .. "/other.db.corrupt-1", "other"))
  assert(Fs.write(path .. "-wal", "unowned"))
  local result = trim(path, "compiles", 5)
  assert(result.complete and #result.report.files[1].removed_set_aside == 1)
  assert(Fs.stat(path .. ".corrupt-1") == nil)
  assert(Fs.read(tmp .. "/other.db.corrupt-1") == "other" and Fs.read(path .. "-wal") == "unowned")
end

local function test_digest_ignores_stamps_pages_and_locations_but_keeps_cell_kinds(tmp: string)
  assert(Fs.mkdirs(tmp .. "/a")); assert(Fs.mkdirs(tmp .. "/b"))
  local a, b = tmp .. "/a/cache.db", tmp .. "/b/cache.db"
  for i, path in ipairs({ a, b }) do
    local db = database(path, formats.compiles)
    compiled(db, "same", i * 10)
    assert(db:exec("CREATE TABLE mixed (a,b,c,d,e); INSERT INTO mixed VALUES (NULL, x'00ff', 'a'||char(0)||'b', 42, 0.5)"))
    assert(db:close())
  end
  local first, second = trim(a, "compiles", 0), trim(b, "compiles", 0)
  assert(first.complete and second.complete)
  assert(first.report.digest == second.report.digest)
  local db = assert(Sqlite.open(b, { writable = true }))
  assert(db:exec("UPDATE mixed SET b = CAST(b AS TEXT)")); assert(db:close())
  local changed = trim(b, "compiles", 0)
  assert(changed.complete and changed.report.digest ~= first.report.digest)
end

local function test_cli_usage_and_json_empty_arrays(tmp: string)
  local output, trouble = "", ""
  local io: cache.Io = {
    out = function(text: string): boolean, string output = output .. text; return true, "" end,
    err = function(text: string) trouble = trouble .. text end,
  }
  local argv: {integer:string} = { [0] = "cosmic", "cache", "trim", "compiles", tmp .. "/missing", "--since-ns", "0", "--json" }
  assert(cache.run(argv, io) == 0 and trouble == "", trouble)
  assert(Json.decode(output) ~= nil and output:find('"warnings":[]', 1, true), output)
  argv[6] = "-1"
  assert(cache.run(argv, io) == 2)
end

local function test_failed_delete_rolls_back_earlier_tables(tmp: string)
  local path = tmp .. "/cache.db"
  local db = database(path, formats.compiles); compiled(db, "old", 1)
  assert(db:exec("INSERT INTO parsed_v1 VALUES ('a','s',0,'',x'','d',0,1)")); assert(db:close())
  local original = Sqlite.run
  Sqlite.run = function(handle: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): boolean, string
    if sql:find('DELETE FROM "parsed_v1"', 1, true) then return false, "injected delete failure" end
    return original(handle, sql, values)
  end
  local result: maintenance.Result
  local ok = pcall(function() result = trim(path, "compiles", 5) end)
  Sqlite.run = original
  assert(ok)
  assert(not result.complete and result.report.digest == nil)
  assert(result.report.files[1].removed == 0 and result.report.files[1].kept == 2)
  assert(count(path, "compiled_v2") == 1 and count(path, "parsed_v1") == 1)
end

local function test_declared_format_without_parts_is_supported_without_migration(tmp: string)
  local path = tmp .. "/verdicts.db"
  local db = database(path, {})
  local old_schema = formats.verdicts[1]:gsub(",%s*parts TEXT NOT NULL DEFAULT ''", "")
  assert(db:exec(old_schema))
  assert(db:exec("INSERT INTO declared_v1 VALUES ('old','test',x'',0,1,'origin'), ('new','test',x'',0,5,'origin')"))
  assert(db:close())
  local result = trim(path, "verdicts", 5)
  assert(result.complete and result.report.files[1].removed == 1)
  db = assert(Sqlite.open(path))
  assert(#assert(Sqlite.text_rows(db, "PRAGMA table_info(declared_v1)")) == 6)
  assert(db:close())
end

local function test_foreign_keys_and_added_constraints_are_kept(tmp: string)
  local path = tmp .. "/cache.db"
  local db = database(path, formats.compiles); compiled(db, "old", 1)
  assert(db:exec("CREATE TABLE dependent (key TEXT REFERENCES compiled_v2(key) ON DELETE CASCADE)"))
  assert(db:exec("INSERT INTO dependent VALUES ('old')")); assert(db:close())
  local result = trim(path, "compiles", 5)
  assert(result.complete and result.report.files[1].removed == 0 and count(path, "dependent") == 1)
  local other = tmp .. "/constrained.db"
  local constrained = formats.compiles[1]:gsub("used_ns INTEGER NOT NULL", "used_ns INTEGER NOT NULL CHECK (used_ns > 0)")
  db = database(other, { constrained }); compiled(db, "old", 1); assert(db:close())
  result = trim(other, "compiles", 5)
  assert(result.complete and #result.report.files[1].unknown_tables == 1 and result.report.files[1].removed == 0)
end

local function test_disappearance_before_open_does_not_recreate_database(tmp: string)
  local path = tmp .. "/cache.db"
  local db = database(path, formats.compiles); compiled(db, "old", 1); assert(db:close())
  local original = Sqlite.open
  Sqlite.open = function(name: string, options?: Sqlite.OpenOptions): Sqlite.Handle | nil, string
    if name == path then assert(Fs.remove(path)) end
    return original(name, options)
  end
  local result: maintenance.Result
  local ok = pcall(function() result = trim(path, "compiles", 5) end)
  Sqlite.open = original
  assert(ok and not result.complete and result.report.digest == nil)
  assert(Fs.stat(path) == nil)
end

local function test_busy_checkpoint_row_suppresses_save_digest(tmp: string)
  local path = tmp .. "/verdicts.db"
  local db = database(path, formats.verdicts); assert(db:close())
  local original = Sqlite.rows
  Sqlite.rows = function(handle: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): {{Sqlite.Cell}} | nil, string
    if sql == "PRAGMA wal_checkpoint(TRUNCATE)" then
      return { { { kind = "integer", integer = 1 }, { kind = "integer", integer = 3 },
        { kind = "integer", integer = 2 } } }, ""
    end
    return original(handle, sql, values)
  end
  local result: maintenance.Result
  local ok = pcall(function() result = trim(path, "verdicts") end)
  Sqlite.rows = original
  assert(ok and not result.complete and result.report.digest == nil)
  assert(result.report.files[1].reason:find("checkpoint", 1, true))
end

--- Captured from the pre-migration CI feed_rows/digest on the same fixture,
--- including NULL, blob, embedded NUL text, integer and floating-point cells.
local function test_existing_ci_digest_golden(tmp: string)
  local path = tmp .. "/cache.db"
  local db = database(path, {})
  assert(db:exec("CREATE TABLE mixed (a,b,c,d,e,used_ns); INSERT INTO mixed VALUES (NULL,x'00ff','a'||char(0)||'b',42,0.5,100)"))
  assert(db:close())
  local result = trim(path, "compiles", 0)
  assert(result.complete, result.report.files[1].reason)
  assert(result.report.digest == "a78d0fce16d987ecc7f27677e5e7003a9f03a4a7cf6a4826fbbc82911ea6bac3", result.report.digest)
end

local function test_vacuum_failure_reports_already_committed_row_counts(tmp: string)
  local path = tmp .. "/cache.db"
  local db = database(path, { formats.compiles[1] }); compiled(db, "old", 1); compiled(db, "new", 5)
  assert(db:close())
  local original = Sqlite.run
  Sqlite.run = function(handle: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): boolean, string
    local ok, why = original(handle, sql, values)
    if ok and sql:find('DELETE FROM "compiled_v2"', 1, true) then
      -- VACUUM needs its temporary attached database; COMMIT needs none.
      local _ = handle:limit("attached", 0)
    end
    return ok, why
  end
  local result: maintenance.Result
  local ok = pcall(function() result = trim(path, "compiles", 5) end)
  Sqlite.run = original
  assert(ok and not result.complete and result.report.digest == nil)
  assert(result.report.files[1].kept == 1 and result.report.files[1].removed == 1)
  assert(count(path, "compiled_v2") == 1, "the delete committed before compaction failed")
end

local function test_one_failed_verdict_file_suppresses_the_aggregate_save(tmp: string)
  local healthy, broken = tmp .. "/healthy.db", tmp .. "/broken.db"
  local db = database(healthy, formats.verdicts)
  assert(db:exec("INSERT INTO stores_v1 VALUES ('a','d',1)")); assert(db:close())
  assert(Fs.write(broken, "unreadable active cache"))
  local result = maintenance.run({ family = "verdicts", paths = { healthy, broken }, whole = true })
  assert(not result.complete and result.report.digest == nil and result.report.fresh == nil)
  assert(#result.report.files == 2 and result.report.files[1].state == "kept" and
    result.report.files[1].kept == 1 and result.report.files[2].state == "failed")
  assert(count(healthy, "stores_v1") == 1 and Fs.read(broken) == "unreadable active cache")
end
