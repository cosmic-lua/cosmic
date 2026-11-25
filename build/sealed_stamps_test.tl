--- [`build.test_key`]'s `sealed_stamps`: a sealed database carries the program's stamp of a walk only where it holds
--- the walk's code as the program does, so the stamp is what a worker on it would work out.

local Sqlite = require("cosmic.sqlite")
local Stamp = require("build.stamp")
local schema = require("build.schema")
local test_key = require("build.test_key")

--- A database of the tool's schema holding the walk of the checker's readers, [`build.pipeline`] and the module it
--- requires, each with a source; `edit` runs on it before its stamps are bound, when given.
local function database(edit?: string): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do assert(db:exec(statement)) end
  assert(db:exec("INSERT INTO modules (path, file, kind, source_hash, key, bytecode, tests, source) VALUES " ..
      "('build.pipeline', 'build/pipeline.tl', 'module', x'01', x'', x'', '', x'0a'), " ..
      "('build.reader', 'build/reader.tl', 'module', x'02', x'', x'', '', x'0b')"))
  assert(db:exec("INSERT INTO imports (path, requires) VALUES ('build.pipeline', 'build.reader')"))
  assert(db:exec("INSERT INTO meta (key, value) VALUES ('compiled_by', 'a compiler'), ('runtime_basis', 'a basis')"))
  if edit ~= nil then assert(db:exec(edit)) end
  return db
end

--- The program's database: [`database`] with the stamp of the walk bound to its rows.
local function program(): Sqlite.Handle
  local db = database()
  local content = assert(Stamp.content(db))
  assert(db:run("INSERT INTO meta (key, value) VALUES ('stamp_of', ?1), ('stamp_coded', 'the code')",
    { { text = content } }))
  return db
end

--- The keys `sealed_stamps` carries into `sealed` of [`program`], joined.
local function carried(sealed: Sqlite.Handle): string
  local keys: mut {string} = {}
  for _, pair in ipairs(test_key.sealed_stamps(sealed, program())) do
    keys[#keys + 1] = pair.key .. "=" .. pair.value
  end
  return table.concat(keys, " ")
end

local function test_a_sealed_database_holding_the_walk_as_the_program_does_carries_its_stamp()
  assert(carried(database()) == "stamp_coded=the code", carried(database()))
end

local function test_a_sealed_database_holding_the_walk_otherwise_carries_no_stamp_of_it()
  for _, edit in ipairs({
      "UPDATE modules SET source = x'' WHERE path = 'build.reader'",
      "UPDATE modules SET source_hash = x'03' WHERE path = 'build.reader'",
      "DELETE FROM modules WHERE path = 'build.reader'",
      "DELETE FROM imports WHERE path = 'build.pipeline'",
  }) do
    local got = carried(database(edit))
    assert(got == "", edit .. " carried " .. got)
  end
end

local function test_a_program_whose_stamps_are_not_of_its_rows_carries_none()
  local moved = program()
  assert(moved:exec("UPDATE modules SET source_hash = x'09' WHERE path = 'build.pipeline'"))
  local got = test_key.sealed_stamps(database("UPDATE modules SET source_hash = x'09' WHERE path = 'build.pipeline'"), moved)
  assert(#got == 0, "a stamp of other rows was carried")
end
