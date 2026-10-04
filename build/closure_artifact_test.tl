--- The artifact [`build.closure_artifact`] makes of a closure: the program's
--- head with a database of the closure's store and of the modules every
--- worker loads, named by both.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local artifact = require("build.artifact")
local closure_artifact = require("build.closure_artifact")
local schema = require("build.schema")

local records = "1\t1\trelease\tx86\tLinux\tx86_64\n"

--- A database at `path` of the tree's schema with a module of each of
--- `paths`, whose bytecode is the path itself, and `main` as its main module.
local function database_at(path: string, paths: {string}, main: string)
  local db = assert(Sqlite.open(path, { writable = true, create = true }))
  for _, statement in ipairs(schema.create("")) do assert(db:exec(statement)) end
  for _, name in ipairs(paths) do
    assert(Sqlite.run(db, "INSERT INTO modules (path, file, kind, source_hash, key, bytecode, " ..
        "tests, source) VALUES (?1, ?1, 'module', X'00', X'', ?1, '', X'')", { { text = name } }))
  end
  assert(Sqlite.run(db, "INSERT INTO meta (key, value) VALUES ('main', ?1)", { { text = main } }))
  assert(db:close())
end

--- The paths of the modules the database `data` holds, sorted, and its main.
local function held(tmp: string, data: string): {string}, string
  assert(Fs.write(tmp .. "/held.db", data))
  local db = assert(Sqlite.open(tmp .. "/held.db"))
  local rows = assert(Sqlite.text_rows(db, "SELECT path FROM modules ORDER BY path"))
  local main = assert(Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'main'"))
  assert(db:close())
  local paths: {string} = {}
  for i, row in ipairs(rows) do paths[i] = row[1] end
  return paths, main[1] ~= nil and main[1][1] or ""
end

--- A program of one fake core and the database made at `path`.
local function program_at(path: string, core: string, paths: {string}, tmp: string)
  local _, _ = Fs.remove(tmp .. "/program.db")
  database_at(tmp .. "/program.db", paths, "cmd.main")
  local prefix = assert(artifact.prefix(records, { x86 = core }))
  local data = assert(Fs.read(tmp .. "/program.db"))
  local program = assert(artifact.program(prefix, data))
  assert(Fs.write(path, program))
end

local function test_the_artifact_of_a_closure_is_the_head_with_the_closure_and_what_workers_load(
    tmp: string)
  program_at(tmp .. "/program", "ELF-core", { "cmd.main", "build.loaded", "build.other", "m" }, tmp)
  database_at(tmp .. "/store.db", { "m", "test.mine" }, "")
  local program = assert(closure_artifact.read(tmp .. "/program"))
  assert(closure_artifact.write(program, tmp .. "/store.db", { "cmd.main", "build.loaded", "m" },
    { "cmd.main", "build.loaded", "build.other", "m", "test.mine" }, tmp .. "/closure.artifact"))
  local bytes = assert(Fs.read(tmp .. "/closure.artifact"))
  local made = assert(artifact.split(bytes))
  assert(made.head == program.parts.head and not made.host)
  local paths, main = held(tmp, made.database)
  -- The closure's, and each module every worker loads that the program has,
  -- and none of the program's others that the tree has.
  assert(table.concat(paths, " ") == "build.loaded cmd.main m test.mine", table.concat(paths, " "))
  assert(main == "cmd.main", main)
  -- Nothing is left beside it.
  assert(Fs.stat(tmp .. "/closure.artifact.building") == nil)
  assert(Fs.stat(tmp .. "/closure.artifact.program") == nil)
end

local function test_the_rows_beside_the_modules_are_those_of_carried_modules_alone(tmp: string)
  program_at(tmp .. "/program", "ELF-core", { "cmd.main", "build.loaded", "build.other" }, tmp)
  local db = assert(Sqlite.open(tmp .. "/program.db", { writable = true }))
  for _, pair in ipairs({ { "cmd.main", "build.loaded" }, { "build.other", "build.loaded" },
      { "build.loaded", "build.other" } }) do
    assert(Sqlite.run(db, "INSERT INTO imports VALUES (?1, ?2)",
      { { text = pair[1] }, { text = pair[2] } }))
    assert(Sqlite.run(db, "INSERT INTO bound VALUES (?1, 'x', ?2)",
      { { text = pair[1] }, { text = pair[2] } }))
  end
  assert(db:close())
  local data = assert(Fs.read(tmp .. "/program.db"))
  local prefix = assert(artifact.prefix(records, { x86 = "ELF-core" }))
  local made = assert(artifact.program(prefix, data))
  assert(Fs.write(tmp .. "/program", made))
  database_at(tmp .. "/store.db", { "m" }, "")
  local program = assert(closure_artifact.read(tmp .. "/program"))
  assert(closure_artifact.write(program, tmp .. "/store.db", { "cmd.main", "build.loaded" },
    { "cmd.main", "build.loaded", "build.other", "m" }, tmp .. "/closure.artifact"))
  local bytes = assert(Fs.read(tmp .. "/closure.artifact"))
  local split = assert(artifact.split(bytes))
  assert(Fs.write(tmp .. "/held.db", split.database))
  local held_db = assert(Sqlite.open(tmp .. "/held.db"))
  -- Imports among the carried modules, and the names each binds.
  local expected: {string:string} = { imports = "cmd.main", bound = "build.loaded cmd.main" }
  for _, table_name in ipairs({ "imports", "bound" }) do
    local rows = assert(Sqlite.text_rows(held_db, "SELECT path FROM " .. table_name ..
        " ORDER BY path"))
    local paths: {string} = {}
    for i, row in ipairs(rows) do paths[i] = row[1] end
    assert(table.concat(paths, " ") == expected[table_name], table.concat(paths, " "))
  end
  assert(held_db:close())
end

local function test_a_module_the_tree_lacks_is_the_programs_to_give(tmp: string)
  program_at(tmp .. "/program", "ELF-core", { "cmd.main", "lib.std", "build.other", "m" }, tmp)
  database_at(tmp .. "/store.db", { "m" }, "")
  local program = assert(closure_artifact.read(tmp .. "/program"))
  assert(closure_artifact.write(program, tmp .. "/store.db", { "cmd.main" },
    { "build.other", "m" }, tmp .. "/closure.artifact"))
  local bytes = assert(Fs.read(tmp .. "/closure.artifact"))
  local made = assert(artifact.split(bytes))
  local paths, _ = held(tmp, made.database)
  assert(table.concat(paths, " ") == "cmd.main lib.std m", table.concat(paths, " "))
end

local function test_a_name_holds_both_the_closure_and_the_program(tmp: string)
  program_at(tmp .. "/one", "ELF-core", { "a" }, tmp)
  program_at(tmp .. "/two", "ELF-other-core", { "a" }, tmp)
  program_at(tmp .. "/same", "ELF-core", { "a", "b" }, tmp)
  local one = assert(closure_artifact.read(tmp .. "/one"))
  local two = assert(closure_artifact.read(tmp .. "/two"))
  local same = assert(closure_artifact.read(tmp .. "/same"))
  assert(closure_artifact.name("ab12", one, {}, {}) ~= closure_artifact.name("ab12", two, {}, {}))
  -- A change of the program's rows is another program: what the artifact
  -- carries of the modules every worker loads is theirs.
  assert(closure_artifact.name("ab12", one, {}, {}) ~= closure_artifact.name("ab12", same, {}, {}))
  assert(closure_artifact.name("ab12", one, {}, {}) ~= closure_artifact.name("cd34", one, {}, {}))
  assert(closure_artifact.name("ab12", one, {}, {}) == closure_artifact.name("ab12", one, {}, {}))
  -- Nor is it the same where what every worker loads, or the tree's modules, are others.
  assert(closure_artifact.name("ab12", one, {}, {}) ~= closure_artifact.name("ab12", one, { "a" }, {}))
  assert(closure_artifact.name("ab12", one, {}, {}) ~= closure_artifact.name("ab12", one, {}, { "a" }))
end

local function test_what_is_no_portable_artifact_has_no_program_to_read(tmp: string)
  assert(Fs.write(tmp .. "/plain", "#!/bin/sh\n"))
  local program, why = closure_artifact.read(tmp .. "/plain")
  assert(program == nil and why:find("trailer", 1, true), tostring(why))
  local missing, absent = closure_artifact.read(tmp .. "/none")
  assert(missing == nil and absent:find("none", 1, true), tostring(absent))
  program_at(tmp .. "/program", "ELF-core", { "a" }, tmp)
  local made = assert(closure_artifact.read(tmp .. "/program"))
  assert(Fs.write(tmp .. "/bad.db", "not a database"))
  local written, trouble = closure_artifact.write(made, tmp .. "/bad.db", {}, {}, tmp .. "/out")
  assert(not written, "a store that is no database")
  assert(trouble ~= "")
  assert(Fs.stat(tmp .. "/out") == nil)
  assert(Fs.stat(tmp .. "/out.building") == nil and Fs.stat(tmp .. "/out.program") == nil)
end
