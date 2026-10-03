--- The shipped module key remains unique and non-null, and a lookup
--- by name does not need unrelated modules' large payloads.

local Sqlite = require("cosmic.sqlite")
local schema = require("build.schema")

local function database(): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do assert(db:exec(statement)) end
  return db
end

local function test_a_module_needs_one_unique_name()
  local db = database()
  local tail = ", 'a.tl', 'module', X'01', X'02', X'03', '', X'04')"
  assert(not db:exec("INSERT INTO modules VALUES (NULL" .. tail),
    "a null module path was accepted")
  assert(db:exec("INSERT INTO modules VALUES ('a'" .. tail))
  assert(not db:exec("INSERT INTO modules VALUES ('a'" .. tail),
    "a duplicate module path was accepted")
  local rows = assert(Sqlite.text_rows(db,
    "SELECT path, file, kind, hex(source_hash), hex(key), hex(bytecode), tests, " ..
    "hex(source) FROM modules WHERE path = 'a'"))
  assert(#rows == 1 and table.concat(rows[1], "|") == "a|a.tl|module|01|02|03||04")
  assert(db:close())
end

--- The name index covers path-only searches even when the module's
--- bytecode and source occupy many overflow pages. The runtime's
--- payload query first finds the same key, then reads that row alone.
local function test_module_names_are_indexed_apart_from_their_payloads()
  local db = database()
  local payload = string.rep("bytecode\0", 4096)
  for _, name in ipairs({ "z", "a", "middle" }) do
    assert(Sqlite.run(db, "INSERT INTO modules VALUES (?1, ?2, 'module', X'01', X'02', " ..
      "?3, '', zeroblob(65536))",
      { { text = name }, { text = name .. ".tl" }, { blob = payload } }))
  end
  local plan = assert(Sqlite.text_rows(db,
    "EXPLAIN QUERY PLAN SELECT path FROM modules WHERE path = 'middle'"))
  assert(#plan == 1 and plan[1][4]:find("COVERING INDEX", 1, true),
    "finding a module name reaches the table's payload: " .. table.concat(plan[1], " "))
  local lookup = "SELECT bytecode, kind FROM main.modules WHERE path = ?1"
  local search = assert(Sqlite.text_rows(db, "EXPLAIN QUERY PLAN " .. lookup,
    { { text = "middle" } }))
  assert(#search == 1 and search[1][4]:find("SEARCH", 1, true) and
    search[1][4]:find("USING INDEX", 1, true), table.concat(search[1], " "))
  local found = assert(Sqlite.rows(db, lookup, { { text = "middle" } }))
  assert(#found == 1 and found[1][1].blob == payload and found[1][2].text == "module")
  local rows = assert(Sqlite.text_rows(db,
    "SELECT file, kind, length(bytecode), length(source) FROM modules WHERE path = 'middle'"))
  assert(#rows == 1 and table.concat(rows[1], "|") == "middle.tl|module|36864|65536")
  local missing = assert(Sqlite.text_rows(db, "SELECT bytecode FROM modules WHERE path = 'none'"))
  assert(#missing == 0)
  assert(db:close())
end
