# Querying an Artifact with SQL

a cosmic artifact is an executable zip: the machine code that runs it,
with a zip archive appended carrying the compiled modules, the type
declarations, the doc index and whatever the project embedded. sqlite
ships with the `zipfile` virtual table, and `cosmic.sqlite` reaches it
with no wrapper and nothing to install, so an artifact is a queryable
database of itself.

no extraction step, no temporary directory, no format change. open an
in-memory database and pass the artifact's path as a parameter:

```sql
SELECT name, sz FROM zipfile('./o/bin/myapp');
```

the columns are the zip's own: `name`, `mode`, `mtime`, `sz`
(uncompressed size), `rawdata`, `data`, `method`. `data` is the
member's decompressed bytes.

## Inspecting what an artifact carries

the question worth asking first is where the bytes went. group the
members by their top-level path:

```sql
SELECT substr(name, 1, instr(name || '/', '/')) AS top,
       count(*) AS n,
       sum(sz) AS bytes
  FROM zipfile('./o/bin/cosmic')
 GROUP BY top
 ORDER BY bytes DESC
 LIMIT 6;
```

against a cosmic binary that answers, in order, `.tl/` (the Teal
compiler's own sources), `.docs/` (one member: the doc index, and the
single largest thing in the file), `make`, `cosmic/` (the standard
library, ~110 members), `tl.lua`, and `.types/`. the zip root is the
module root, which is why `require("cosmic.fs")` resolves to
`/zip/cosmic/fs.lua` and why the members read like import paths.

that query works on any zip file. an artifact is not a special case —
it is a zip that happens to have a program in front of it.

## Extracting a member

`data` is bytes; `CAST(data AS TEXT)` is the readable form:

```sql
SELECT CAST(data AS TEXT) FROM zipfile('./o/bin/cosmic')
 WHERE name = 'cosmic.mk';
```

that returns the make rules the binary ships at `/zip/cosmic.mk`, as
text. `sys/help.md` — what `--help` prints — comes out the same way.

**the modules do not.** every `cosmic/*.lua` member is *precompiled
bytecode*: its first four bytes are `\27Lua`, a chunk header, not
source. a `SELECT` will hand you the chunk and the cast will hand you
mojibake. to read a module, ask the binary:

```text
cosmic --docs cosmic.fs        # the module's reference
cosmic --docs guide.modules    # the standard library tour
```

SQL is the right tool for *what is in here and how big is it*. it is
the wrong tool for *what does this module do*.

## Editing an artifact

`zipfile` is writable. declared as a virtual table over a path, it
accepts `INSERT` and `DELETE`:

```sql
CREATE VIRTUAL TABLE z USING zipfile('/tmp/copy-of-myapp');
INSERT INTO z(name, data) VALUES ('hello.txt', 'hi from sql');
```

the edited binary still runs, and serves the new member through the
zip filesystem: `io.open("/zip/hello.txt")` reads back `hi from sql`.

**work on a copy.** the artifact you are running is the one you would
be editing, and a program that rewrites its own zip while executing
from it is asking for the failure it will get. copy first with
`fs.copy`, and edit the copy. nothing else is needed to make the copy
runnable: `fs.copy` chmods the destination to the source's mode, so an
artifact copied out of an artifact is still executable.

## Deleting, and what it costs

`DELETE` works too, and the cost is worth stating plainly:

```sql
DELETE FROM z WHERE name LIKE '.docs/%';
```

**the file gets bigger.** `zipfile` appends a fresh central directory
rather than rewriting the archive, so removing a 1.6 MB member from an
11 MB binary grew it by roughly 38 KB. nothing is reclaimed; there is
no vacuum. deleting is how you make a member unreachable, not how you
make an artifact smaller.

**the binary survives; the feature may not.** after deleting the doc
index, the binary still runs ordinary programs — and `cosmic --docs`
exits 1, because the payload it reads is gone. that is the honest
shape of editing an artifact: the zip stays valid and the program that
depended on the member does not.

if the goal is a smaller artifact, build a smaller one. `cosmic
--make` decides what a binary carries from what the project contains,
and `cosmic --docs guide.make` is where that model is written down.

## In Teal

the SQL above is what `cosmic.sqlite` runs. the runnable version of
this guide is `cosmic/sqlite/zipfile_example.tl`, and the shape is:

```teal
local check = require("cosmic.check")
local proc = require("cosmic.proc")
local sqlite = require("cosmic.sqlite")

local exe = check.must(proc.interpreter())
local db = check.must(sqlite.open(":memory:"))
for row in check.must(db:query(
    "SELECT count(*) AS n FROM zipfile(?)", {exe})) do
  print(row.n)
end
assert(db:close())
```

`proc.interpreter()` is the running cosmic binary's own path.
`arg[0]` is not it — inside an artifact that is `/zip/main.lua`, the
script the runtime loaded, which is a member rather than the file.

related: `cosmic --docs cosmic.sqlite` for the module,
`cosmic --docs guide.make` for what decides an artifact's contents,
`cosmic --docs cosmic.zip` for reading and writing zips without SQL,
and `cosmic --docs cosmic.embed` for putting files into an executable
in the first place.
