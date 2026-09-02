# Inspect an artifact with SQL

steps for listing, reading and editing the members of a cosmic artifact
through sqlite's `zipfile` table, for a reader who knows SQL.

sqlite ships the `zipfile` virtual table, and `cosmic.sqlite` reaches it
with nothing to install. `cosmic --docs explanation.artifact` says why
an artifact is a zip in the first place.

## list the members

open an in-memory database and pass the artifact's path as a parameter.
there is no extraction step and no temporary directory:

```sql
SELECT name, sz FROM zipfile('./o/bin/myapp');
```

the columns are the zip's own: `name`, `mode`, `mtime`, `sz` (the
uncompressed size), `rawdata`, `data` (the decompressed bytes) and
`method`.

from Teal, name the running artifact with `proc.interpreter()`:

```teal example=cosmic/sqlite/zipfile_example.tl#Example_inspect_members
local check = require("cosmic.check")
local proc = require("cosmic.proc")
local sqlite = require("cosmic.sqlite")

local exe = check.must(proc.interpreter())
local db = check.must(sqlite.open(":memory:"))
local row = check.must(db:query_one(
    "SELECT count(*) AS members," ..
    " sum(name LIKE 'cosmic/%') AS modules FROM zipfile(?)", {exe}))
print(tonumber(row.members) > 0, tonumber(row.modules) > 0)

-- Members are named by their path inside the zip, and the zip root
-- is the module root: require("cosmic.fs") loads /zip/cosmic/fs.lua.
local named = check.must(db:query_one(
    "SELECT name FROM zipfile(?) WHERE name = 'cosmic/fs.lua'", {exe}))
print(named.name)
assert(db:close())
-- Output:
-- true	true
-- cosmic/fs.lua
```

## group by top-level path

to see where the bytes went, group the members by their first path
segment:

```sql
SELECT substr(name, 1, instr(name || '/', '/')) AS top,
       count(*) AS n,
       sum(sz) AS bytes
  FROM zipfile('./o/bin/cosmic')
 GROUP BY top
 ORDER BY bytes DESC
 LIMIT 6;
```

against a cosmic binary the largest groups are `.tl/` (the Teal
compiler's sources), `.docs/` (one member, the doc index), `make`,
`cosmic/` (the standard library), `tl.lua` and `.types/`. the members
read like import paths because the zip root is the module root:
`require("cosmic.fs")` resolves to `/zip/cosmic/fs.lua`.

the query works on any zip file. an artifact is a zip with a program in
front of it.

## extract a text member

`data` is bytes. `CAST(data AS TEXT)` is the readable form:

```sql
SELECT CAST(data AS TEXT) FROM zipfile('./o/bin/cosmic')
 WHERE name = 'cosmic.mk';
```

that returns the make rules the binary ships at `/zip/cosmic.mk`.
`sys/help.md`, which is what `--help` prints, comes out the same way.

a module does not. every `cosmic/*.lua` member is precompiled bytecode.
its first four bytes are `\27Lua`, a chunk header, not source, and the
cast hands you mojibake. read a module's reference with
`cosmic --docs cosmic.fs`, not SQL. SQL answers "what is in here and how
big is it", never "what does this module do".

```teal example=cosmic/sqlite/zipfile_example.tl#Example_extract_member
local check = require("cosmic.check")
local proc = require("cosmic.proc")
local sqlite = require("cosmic.sqlite")

local exe = check.must(proc.interpreter())
local db = check.must(sqlite.open(":memory:"))

-- cosmic.mk is the make ruleset the binary ships at /zip/cosmic.mk.
local mk = check.must(db:query_one(
    "SELECT CAST(data AS TEXT) AS text FROM zipfile(?)" ..
    " WHERE name = 'cosmic.mk'", {exe}))
print((tostring(mk.text):gsub("\n.*", "")))

-- A module is precompiled bytecode, not source: its first bytes are
-- a Lua chunk header. Read a module with `cosmic --docs`, not SQL.
local mod = check.must(db:query_one(
    "SELECT CAST(data AS TEXT) AS text FROM zipfile(?)" ..
    " WHERE name = 'cosmic/json.lua'", {exe}))
print(tostring(mod.text):sub(2, 4))
assert(db:close())
-- Output:
-- # cosmic.mk — the rules for `cosmic --make`.
-- Lua
```

## add a member to a copy

work on a copy. the artifact you run is the one you would edit, and a
program that rewrites the zip it executes from fails.

1. copy the artifact with `fs.copy`. it carries the mode bits across,
   so the copy stays executable.
2. declare `zipfile` as a virtual table over the copy's path.
3. `INSERT` the member.

```sql
CREATE VIRTUAL TABLE z USING zipfile('/tmp/copy-of-myapp');
INSERT INTO z(name, data) VALUES ('hello.txt', 'hi from sql');
```

the edited binary still runs, and serves the member through the zip
filesystem: `io.open("/zip/hello.txt")` reads back `hi from sql`.

```teal example=cosmic/sqlite/zipfile_example.tl#Example_add_member
local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local sqlite = require("cosmic.sqlite")

local exe = check.must(proc.interpreter())
local dir = check.must(fs.temp_dir())
local copy = fs.join(dir, "artifact")
-- fs.copy carries the mode across, so the copy stays executable.
check.must(fs.copy(exe, copy))

local db = check.must(sqlite.open(":memory:"))
check.must(db:exec("CREATE VIRTUAL TABLE z USING zipfile('" .. copy .. "')"))
check.must(db:exec(
    "INSERT INTO z(name, data) VALUES ('hello.txt', 'hi from sql')"))
assert(db:close())

-- The edited binary still runs, and serves the member through /zip.
local ran = check.must(child.run({copy, "-e",
      "local f = assert(io.open('/zip/hello.txt')) io.write(f:read('a')) f:close()"}))
print(ran.stdout)
check.must(fs.remove_all(dir))
-- Output:
-- hi from sql
```

## delete a member, and what it costs

`DELETE` works on the same virtual table:

```sql
DELETE FROM z WHERE name LIKE '.docs/%';
```

the file gets bigger. `zipfile` appends a fresh central directory
instead of rewriting the archive, so removing the 2 MB doc index from a
cosmic binary grows the file by tens of kilobytes. nothing is reclaimed,
and there is no vacuum. deleting makes a member unreachable; it does not
make an artifact smaller.

the binary survives; the feature does not. after the delete above, the
binary still runs ordinary programs, and `cosmic --docs` exits 1 because
the payload it reads is gone.

```teal example=cosmic/sqlite/zipfile_example.tl#Example_remove_member
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local sqlite = require("cosmic.sqlite")

local exe = check.must(proc.interpreter())
local dir = check.must(fs.temp_dir())
local copy = fs.join(dir, "artifact")
-- fs.copy carries the mode across, so the copy stays executable.
check.must(fs.copy(exe, copy))
local before = check.must(fs.stat(copy)):size()

local db = check.must(sqlite.open(":memory:"))
check.must(db:exec("CREATE VIRTUAL TABLE z USING zipfile('" .. copy .. "')"))
check.must(db:exec("DELETE FROM z WHERE name LIKE '.docs/%'"))
assert(db:close())

local after = check.must(fs.stat(copy)):size()

local reread = check.must(sqlite.open(":memory:"))
local left = check.must(reread:query_one(
    "SELECT count(*) AS n FROM zipfile(?) WHERE name LIKE '.docs/%'",
    {copy}))
assert(reread:close())
print("members left: " .. tostring(tonumber(left.n)))
print("file smaller: " .. tostring(after < before))
check.must(fs.remove_all(dir))
-- Output:
-- members left: 0
-- file smaller: false
```

for a smaller artifact, build a smaller one. `cosmic --make` decides
what a binary carries from what the project contains.
`cosmic --docs howto.build` has the steps, and
`cosmic --docs explanation.artifact` says what ships and why.

`cosmic --docs cosmic.sqlite` has the module's signatures.
`cosmic --docs cosmic.zip` reads and writes zips without SQL, and
`cosmic --docs cosmic.embed` puts files into an executable.
