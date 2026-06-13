--- Examples for the cosmic.sqlite module.
--- Demonstrates database operations, prepared statements, and queries.

-- Example_open_file demonstrates database file path resolution
local function Example_open_file()
  local sqlite = require("cosmic.sqlite")
  local fs = require("cosmic.fs")

  -- Relative paths resolve against cwd
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local dbpath = fs.join(tmpdir, "example.db")
  local db = sqlite.open(dbpath)
  db:exec("CREATE TABLE t (x TEXT)")
  db:exec("INSERT INTO t (x) VALUES ('hello')")
  local row = db:query_one("SELECT x FROM t")
  print(row.x)
  db:close()
  os.remove(dbpath)

  -- Absolute paths work as expected:
  --   local db = sqlite.open("/var/data/app.db")
  -- In-memory databases are not written to disk:
  --   local db = sqlite.open(":memory:")
  -- Output:
  -- hello
end

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

-- Example_query_like demonstrates substring matching with LIKE
-- (the SQL wildcard is %, not *)
local function Example_query_like()
  local sqlite = require("cosmic.sqlite")
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE files (path TEXT)")
  db:exec("INSERT INTO files (path) VALUES (?)", "src/main.tl")
  db:exec("INSERT INTO files (path) VALUES (?)", "src/util.tl")
  db:exec("INSERT INTO files (path) VALUES (?)", "docs/readme.md")

  for row in db:query("SELECT path FROM files WHERE path LIKE ?", "%src%") do
    print(row.path)
  end
  db:close()
  -- Output:
  -- src/main.tl
  -- src/util.tl
end

return {}
