--- [`build.stamps`]' `fill` writes stamps only where the code working
--- them out is the code the database carries.

local Sqlite = require("cosmic.sqlite")
local Stamp = require("build.stamp")
local schema = require("build.schema")
local stamps = require("build.stamps")

--- A database of the tool's schema that carries build.stamps, whose
--- source hashes to `own`, and a module it requires, whose source hashes
--- to `required`; and a module nothing of it requires, hashing to `other`.
local function carrying(own: string, required: string, other: string): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do assert(db:exec(statement)) end
  local hashes: {string:string} = { ["build.stamps"] = own, ["build.required"] = required, ["build.other"] = other }
  for path, hash in pairs(hashes) do
    assert(Sqlite.run(db, "INSERT INTO modules (path, file, kind, source_hash, key, bytecode, tests, source) " ..
        "VALUES (?1, '', 'module', ?2, x'', x'', '', x'')", { { text = path }, { text = hash } }))
  end
  assert(db:exec("INSERT INTO imports (path, requires) VALUES ('build.stamps', 'build.required')"))
  assert(db:exec("INSERT INTO meta (key, value) VALUES ('stamp_coded', 'left by another writer')"))
  return db
end

--- The rows of `db`'s `meta` that are stamps, as `key=value` lines.
local function stamps_of(db: Sqlite.Handle): string
  local rows = assert(Sqlite.text_rows(db, "SELECT key || '=' || value FROM meta WHERE key LIKE 'stamp%' ORDER BY key"))
  local lines: mut {string} = {}
  for i, row in ipairs(rows) do lines[i] = row:text(1) end
  return table.concat(lines, "\n")
end

--- A stale tool rebuilding a tree whose stamping code moved runs the old
--- code: a stamp it worked out would be trusted by the tool it writes,
--- which carries the new. It writes none, and takes out any that were
--- there.
local function test_a_writer_whose_stamping_code_is_not_the_databases_writes_no_stamp()
  for _, running in ipairs({ carrying("1", "another", "3"), carrying("another", "2", "3") }) do
    local db = carrying("1", "2", "3")
    assert(stamps.fill(db, running))
    assert(stamps_of(db) == "", stamps_of(db))
  end
end

--- An edit outside the stamping code leaves a tool free to stamp the
--- tree it rebuilds: the rows are bound (`stamp_of`), and what was there
--- is replaced.
local function test_a_writer_whose_stamping_code_is_the_databases_binds_its_stamps()
  local db = carrying("1", "2", "3")
  assert(stamps.fill(db, carrying("1", "2", "another")))
  local bound = assert(Stamp.read(Stamp.of, db), stamps_of(db))
  assert(bound == assert(Stamp.content(db)))
  assert(Stamp.read("stamp_coded", db) ~= "left by another writer", stamps_of(db))
end

--- A database that does not carry the stamping code is no tool's: nothing
--- says the code here is what would read its stamps.
local function test_a_database_without_the_stamping_code_is_not_stamped()
  local db, running = carrying("1", "2", "3"), carrying("1", "2", "3")
  for _, each in ipairs({ db, running }) do
    assert(each:exec("DELETE FROM modules WHERE path = 'build.stamps'"))
  end
  assert(stamps.fill(db, running))
  assert(stamps_of(db) == "", stamps_of(db))
end
