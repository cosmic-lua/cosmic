# a command-line tool with SQLite

build `notes`, a small command-line tool with two subcommands. `notes
add <text>` stores a note in a SQLite file and `notes list` prints
every note. on the way you use four standard library modules, write a
test that runs in a scratch directory, and write an example whose
output the gate checks. the page takes about twenty minutes.

do `cosmic --docs tutorial.quickstart` first. this page assumes you
know the layout rules and the four build commands from it.

## 1. make the project

```bash
mkdir notes-project
cd notes-project
```

the finished project has this layout:

```text
notes-project/
  cmd/notes/main.tl        the binary
  notes/store.tl           the storage module: require("notes.store")
  notes/store_test.tl      its test
  notes/store_example.tl   its example, with checked output
```

## 2. write the storage module

create `notes/store.tl`. the module owns the SQL. it opens a database,
creates the table, inserts a note, and lists the notes as typed
records. every function that can fail returns `nil` and a message:

```teal file=notes/store.tl
local sqlite = require("cosmic.sqlite")

local record StoreModule
  record Note
    id: integer
    text: string
  end
  open: function(path: string): sqlite.Database | nil, string
  add: function(db: sqlite.Database, text: string): integer | nil, string
  list: function(db: sqlite.Database): {Note} | nil, string
end

local function open(path: string): sqlite.Database | nil, string
  local db, open_err = sqlite.open(path)
  if not db then
    return nil, open_err
  end
  local ok, exec_err = db:exec(
    "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, text TEXT NOT NULL)")
  if not ok then
    return nil, exec_err
  end
  return db
end

local function add(db: sqlite.Database, text: string): integer | nil, string
  local ok, exec_err = db:exec("INSERT INTO notes (text) VALUES (?)", {text})
  if not ok then
    return nil, exec_err
  end
  return db:last_insert_rowid()
end

local function list(db: sqlite.Database): {StoreModule.Note} | nil, string
  local rows, query_err = db:query("SELECT id, text FROM notes ORDER BY id")
  if not rows then
    return nil, query_err
  end
  local notes: {StoreModule.Note} = {}
  for row in rows do
    local id, id_err = sqlite.column_integer(row, "id")
    if not id then
      return nil, id_err
    end
    local text, text_err = sqlite.column_text(row, "text")
    if not text then
      return nil, text_err
    end
    notes[#notes + 1] = {id = id, text = text}
  end
  return notes
end

local M: StoreModule = {
  open = open,
  add = add,
  list = list,
}

return M
```

three things to notice. `Note` is nested inside `StoreModule`, so
another file can write `store.Note`. `sqlite.column_integer` and
`sqlite.column_text` read a column as one type, so the module never
casts. `open` closes over nothing and shadows nothing: `io.open` is
still `io.open`.

## 3. write the binary

create `cmd/notes/main.tl`. `cosmic.flags` parses the subcommands from
a spec and never prints or exits by itself. `cosmic.main` turns your
return values into the exit code and the error output:

```teal file=cmd/notes/main.tl
local cosmic = require("cosmic")
local flags = require("cosmic.flags")
local store = require("notes.store")

local spec: flags.CommandSpec = {
  name = "notes",
  summary = "keep short notes in a SQLite file",
  commands = {
    {name = "add", summary = "add a note", spec = {usage = "<text...>", flags = {}}},
    {name = "list", summary = "list every note", spec = {flags = {}}},
  },
}

cosmic.main(function(args: {string}, env: cosmic.Env): number, string
    local dispatch, dispatch_err = flags.command(spec, args)
    if not dispatch then
      env.stderr:write(flags.command_help(spec) .. "\n")
      return 2, "notes: " .. dispatch_err
    end
    if dispatch.help then
      print(flags.command_help(spec, dispatch.command))
      return 0
    end
    local db, open_err = store.open("notes.db")
    if not db then
      return 1, "notes: " .. open_err
    end
    if dispatch.command == "add" then
      local id, add_err = store.add(db, table.concat(dispatch.parsed.args, " "))
      if not id then
        return 1, "notes: " .. add_err
      end
      print(id)
    else
      local notes, list_err = store.list(db)
      if not notes then
        return 1, "notes: " .. list_err
      end
      for _, note in ipairs(notes) do
        print(note.id, note.text)
      end
    end
    assert(db:close())
    return 0
  end)
```

## 4. write the test

create `notes/store_test.tl`. the runner sets `TEST_TMPDIR` to a
fresh directory for the file, so the test opens its database there:

```teal file=notes/store_test.tl
#!/usr/bin/env cosmic
local check = require("cosmic.check")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local store = require("notes.store")

local function test_add_then_list()
  local dir = check.must(env.get("TEST_TMPDIR"))
  local db = check.must(store.open(fs.join(dir, "notes.db")))
  local id = check.must(store.add(db, "buy milk"))
  check.equal(id, 1, "first rowid")
  local notes = check.must(store.list(db))
  check.equal(#notes, 1, "one note")
  check.equal(notes[1].text, "buy milk", "text")
  assert(db:close())
end
```

`check.must` narrows a fallible return: it returns the value, or fails
the test with the callee's own message. `check.equal` prints both
values when they differ.

## 5. write the example

create `notes/store_example.tl`. an example is a function whose name
starts with `Example_`. the `-- Output:` block is what the function
prints, and the gate fails when the two differ:

```teal file=notes/store_example.tl
local function Example_add_and_list()
  local check = require("cosmic.check")
  local store = require("notes.store")
  local db = check.must(store.open(":memory:"))
  check.must(store.add(db, "buy milk"))
  check.must(store.add(db, "call mom"))
  for _, note in ipairs(check.must(store.list(db))) do
    print(note.id, note.text)
  end
  -- Output:
  -- 1	buy milk
  -- 2	call mom
end

local _ = {Example_add_and_list}
```

the last line keeps the checker quiet about an unused function. the
example runner finds the function by name.

## 6. build and run it

```bash
cosmic --make build
# make: o/bin/notes
# build: PASS (4 files, 1 binary)
```

```bash
o/bin/notes add buy milk
# 1
```

```bash
o/bin/notes add call mom
# 2
```

```bash
o/bin/notes list
# 1	buy milk
# 2	call mom
```

`o/bin/notes --help` prints the overview that `cosmic.flags` renders
from the spec, and `o/bin/notes add --help` prints the page for one
subcommand.

## 7. test it and run the gate

```bash
cosmic --make test
# test: PASS (1 file)
```

```bash
cosmic --make ci
# ci: PASS (5 stages)
```

five stages this time: the `example` stage ran `Example_add_and_list`
and compared its output with the `-- Output:` block.

## what you learned

- a module owns one concern and returns `nil, message` when it fails.
- nest a record in the module's interface record to export its type.
- `cosmic.flags` turns a spec into parsing and `--help`; your code
  decides what to do with the result.
- `TEST_TMPDIR` is where a test writes.
- an `Example_*` function with an `-- Output:` block is a test of
  what the code prints.

## next

- `cosmic --docs howto.cli-script` has the shape of a single-command
  tool with JSON input.
- `cosmic --docs howto.test` covers the test sandbox and spawning the
  built binary from a test.
- `cosmic --docs cosmic.flags` and `cosmic --docs cosmic.sqlite` are
  the two modules' references.
