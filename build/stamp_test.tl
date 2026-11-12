--- [`build.stamp`]: a stamp is answered only of the rows it was made for.

local Sqlite = require("cosmic.sqlite")
local Stamp = require("build.stamp")
local schema = require("build.schema")

--- A database of the tool's schema holding two modules, a declaration,
--- what they require, the `meta` rows a stamp's binding reads, and one
--- stamp bound to those rows.
local function stamped(): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do assert(db:exec(statement)) end
  assert(db:exec("INSERT INTO modules (path, file, kind, source_hash, key, bytecode, tests, source) VALUES " ..
      "('a', 'a.tl', 'module', x'01', x'', x'', '', x''), ('b', 'b.tl', 'module', x'02', x'', x'', '', x'')"))
  assert(db:exec("INSERT INTO imports (path, requires) VALUES ('a', 'b')"))
  assert(db:exec("INSERT INTO decl_imports (path, requires) VALUES ('a', 'b')"))
  assert(db:exec("INSERT INTO decls (path, source) VALUES ('a.d', deflate('declared'))"))
  assert(db:exec("INSERT INTO meta (key, value) VALUES ('compiled_by', 'a compiler'), ('runtime_basis', 'a basis')"))
  local content = assert(Stamp.content(db))
  assert(Sqlite.run(db, "INSERT INTO meta (key, value) VALUES ('stamp_of', ?1), ('stamp_coded', 'the code')",
    { { text = content } }))
  return db
end

local function test_a_stamp_bound_to_the_rows_is_answered()
  local db = stamped()
  assert(Stamp.read("stamp_coded", db) == "the code")
  assert(Stamp.read("stamp_harness", db) == nil, "a stamp the database holds no row of")
end

--- Each row a stamp is a function of is in the binding: a database whose
--- rows moved after its stamps were made, or that was handed the stamps
--- of another, answers none, and the caller works the value out.
local function test_a_stamp_is_not_answered_once_a_row_it_was_made_of_moves()
  local moves: {string} = {
    "UPDATE modules SET source_hash = x'03' WHERE path = 'b'",
    "UPDATE modules SET kind = 'main' WHERE path = 'b'",
    "INSERT INTO modules (path, file, kind, source_hash, key, bytecode, tests, source) VALUES " ..
      "('c', 'c.tl', 'module', x'04', x'', x'', '', x'')",
    "DELETE FROM modules WHERE path = 'b'",
    "INSERT INTO imports (path, requires) VALUES ('b', 'a')",
    "DELETE FROM imports",
    "INSERT INTO decl_imports (path, requires) VALUES ('b', 'a')",
    "INSERT INTO decls (path, source) VALUES ('b', deflate('declared'))",
    "UPDATE decls SET source = deflate('declared otherwise') WHERE path = 'a.d'",
    "UPDATE meta SET value = 'another compiler' WHERE key = 'compiled_by'",
    "UPDATE meta SET value = 'another basis' WHERE key = 'runtime_basis'",
    "DELETE FROM meta WHERE key = 'compiled_by'",
  }
  for _, move in ipairs(moves) do
    local db = stamped()
    assert(db:exec(move))
    assert(Stamp.read("stamp_coded", db) == nil, "still answered after: " .. move)
  end
end

local function test_a_stamp_with_no_binding_or_another_is_not_answered()
  local unbound = stamped()
  assert(unbound:exec("DELETE FROM meta WHERE key = 'stamp_of'"))
  assert(Stamp.read("stamp_coded", unbound) == nil)
  local other = stamped()
  assert(other:exec("UPDATE meta SET value = 'another database' WHERE key = 'stamp_of'"))
  assert(Stamp.read("stamp_coded", other) == nil)
  local empty = stamped()
  assert(empty:exec("UPDATE meta SET value = '' WHERE key = 'stamp_of'"))
  assert(Stamp.read("stamp_coded", empty) == nil)
end

--- A row no stamp is made of moves no binding: a tool whose time zones or
--- roots were replaced keeps its stamps.
local function test_a_row_no_stamp_is_made_of_leaves_the_stamps()
  local db = stamped()
  assert(db:exec("INSERT INTO meta (key, value) VALUES ('boot_hash', 'a tree')"))
  assert(db:exec("INSERT INTO zoneinfo (name, data) VALUES ('UTC', x'00')"))
  assert(Stamp.read("stamp_coded", db) == "the code")
end
