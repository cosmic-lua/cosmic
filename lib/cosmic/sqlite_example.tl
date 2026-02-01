--- Examples for the cosmic.sqlite module.
--- Demonstrates database operations, prepared statements, and queries.

-- Example_open demonstrates opening an in-memory database
local function Example_open()
  local sqlite = require("cosmic.sqlite")
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)")
  db:exec("INSERT INTO kv (k, v) VALUES ('hello', 'world')")
  for row in db:query("SELECT * FROM kv") do
    print(row.k, row.v)
  end
  db:close()
  -- Output:
  -- hello	world
end

-- Example_prepared demonstrates prepared statements
local function Example_prepared()
  local sqlite = require("cosmic.sqlite")
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

  local stmt = db:prepare("INSERT INTO users (name) VALUES (?)")
  stmt:bind("Alice")
  stmt:exec()
  stmt:reset()
  stmt:bind("Bob")
  stmt:exec()
  stmt:close()

  for row in db:query("SELECT * FROM users ORDER BY id") do
    print(row.id, row.name)
  end
  db:close()
  -- Output:
  -- 1	Alice
  -- 2	Bob
end

-- Example_query_params demonstrates query with parameters
local function Example_query_params()
  local sqlite = require("cosmic.sqlite")
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE nums (n INTEGER)")
  for i = 1, 5 do
    db:exec("INSERT INTO nums (n) VALUES (" .. i .. ")")
  end

  for row in db:query("SELECT * FROM nums WHERE n > ?", 2) do
    print(row.n)
  end
  db:close()
  -- Output:
  -- 3
  -- 4
  -- 5
end

-- Example_exec_params demonstrates exec with parameter binding
local function Example_exec_params()
  local sqlite = require("cosmic.sqlite")
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE cities (id INTEGER PRIMARY KEY, name TEXT, pop INTEGER)")

  db:exec("INSERT INTO cities (name, pop) VALUES (?, ?)", "Tokyo", 13960000)
  db:exec("INSERT INTO cities (name, pop) VALUES (?, ?)", "Delhi", 16787941)
  db:exec("INSERT INTO cities (name, pop) VALUES (?, ?)", "Shanghai", 24870895)

  for row in db:query("SELECT * FROM cities ORDER BY pop DESC") do
    print(row.name, row.pop)
  end
  db:close()
  -- Output:
  -- Shanghai	24870895
  -- Delhi	16787941
  -- Tokyo	13960000
end

return {}
