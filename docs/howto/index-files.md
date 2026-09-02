# Index files into sqlite

steps for walking a tree, hashing each file, and storing the results in
a sqlite table you can query, for a reader who knows `cosmic.fs` and SQL.

## steps

1. open the database with `sqlite.open` and create the table. make
   `path` the primary key, so a second run updates rows instead of
   adding duplicates.
2. walk the tree with `fs.visit`. the visitor receives an `fs.Entry`.
   `e.path` is the full path. never join it with `e.name`. `e:stat()`
   is lazy and memoized, so call it only where the walk needs it.
3. annotate the visitor's parameter as `fs.Entry`, from the public
   `cosmic.fs` module. `cosmic.fs.types` is an internal shard, and the
   lint refuses it from outside `cosmic/`.
4. hash each regular file with `hash.sha256_hex`.
5. upsert with `INSERT ... ON CONFLICT(path) DO UPDATE`. `db:exec`
   binds the parameter list to the `?` placeholders.
6. query by substring with `LIKE`. the wildcard is `%`, not `*`.
7. close the database.

## the program

```teal
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local sqlite = require("cosmic.sqlite")

local db = check.must(sqlite.open("index.db"))
assert(db:exec("CREATE TABLE IF NOT EXISTS files (" ..
    "path TEXT PRIMARY KEY, size INTEGER, digest TEXT)"))

local upsert = [[
INSERT INTO files (path, size, digest) VALUES (?, ?, ?)
ON CONFLICT(path) DO UPDATE SET size = excluded.size, digest = excluded.digest
]]

check.must(fs.visit("src", function(e: fs.Entry, _ctx: any)
      -- e.path is the full path; do not join it with e.name
      local st, stat_err = e:stat()
      if not st then
        io.stderr:write("skip " .. e.path .. ": " .. stat_err .. "\n")
      elseif st:is_file() then
        local data, read_err = fs.read(e.path)
        if not data then
          io.stderr:write("skip " .. e.path .. ": " .. read_err .. "\n")
        else
          assert(db:exec(upsert, {e.path, st:size(), hash.sha256_hex(data)}))
        end
      end
    end))

-- substring query: LIKE uses % as the wildcard, not *
for row in check.must(db:query("SELECT * FROM files WHERE path LIKE ?",
    {"%main%"})) do
  print(row.path, row.size, row.digest)
end
assert(db:close())
```

`fs.visit`'s slot 2 is the failure to open the root. errors under the
root ride on the returned record as `.errors`, which is nil when the
walk is clean.

## the pieces on their own

`fs.visit` and the `Entry` it hands the visitor:

```teal example=cosmic/fs/walk_example.tl#Example_visit
local check = require("cosmic.check")
local fs = require("cosmic.fs")

-- Build a small tree under a temp directory.
local base = os.getenv("TEST_TMPDIR") or "/tmp"
local tmpdir = fs.temp_dir(fs.join(base, "walk_ex_XXXXXX"))
assert(tmpdir, "temp_dir failed")

local subdir = fs.join(tmpdir, "conf")
assert(fs.make_dirs(subdir))
assert(fs.write(fs.join(subdir, "app.ini"), "[app]\nname=test\n"))
assert(fs.write(fs.join(tmpdir, "README"), "readme\n"))

-- Collect entries and sort for deterministic output.
local entries: {string} = {}
assert(fs.visit(tmpdir, function(e: fs.Entry, ctx: {string})
      local st = check.must(e:stat())
      local kind = st:is_dir() and "dir" or "file"
      table.insert(ctx, kind .. " " .. e.name .. " depth=" .. e.depth)
    end, entries))

table.sort(entries)
for _, line in ipairs(entries) do
  print(line)
end

assert(fs.remove_all(tmpdir))
-- Output:
-- dir conf depth=1
-- file README depth=1
-- file app.ini depth=2
```

a `LIKE` query with a bound parameter:

```teal example=cosmic/sqlite/init_example.tl#Example_query_like
local check = require("cosmic.check")
local sqlite = require("cosmic.sqlite")
local db = check.must(sqlite.open(":memory:"))
assert(db:exec("CREATE TABLE files (path TEXT)"))
assert(db:exec("INSERT INTO files (path) VALUES (?)", {"src/main.tl"}))
assert(db:exec("INSERT INTO files (path) VALUES (?)", {"src/util.tl"}))
assert(db:exec("INSERT INTO files (path) VALUES (?)", {"docs/readme.md"}))

for row in check.must(db:query("SELECT path FROM files WHERE path LIKE ?", {"%src%"})) do
  print(row.path)
end
assert(db:close())
-- Output:
-- src/main.tl
-- src/util.tl
```

`cosmic --docs cosmic.fs`, `cosmic --docs cosmic.hash` and
`cosmic --docs cosmic.sqlite` have the signatures.
