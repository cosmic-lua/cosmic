# quickstart

<!-- needs: processes = true, tool = true -->

cosmic is one executable: the Lua runtime, the Teal compiler, and a
standard library, `cosmic.*`, for the everyday things a script needs.
This guide uses several of those modules and shows what they do.

## hashing bytes

`cosmic.hash` turns a string into its SHA-256 digest, as 64 lowercase
hex characters.

```teal
local Hash = require("cosmic.hash")

print(Hash.hex_sha256("cosmic"))
```

```output
01307b41e7ff0bb31cca03fb7ff5bea9fdb3dd83afaca63d588a0c07e7ae98b8
```

## reading a file back

`cosmic.fs` reads and writes files. This example is two pieces: a
companion file, `notes.txt`, and the entry code that reads it.

```teal file=notes.txt
hello from notes.txt
```

```teal
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")

local content, trouble = Fs.read(tmp .. "/notes.txt")
if content == nil then
  error(trouble)
end
print(content)
print(Hash.hex_sha256(content))
```

```output
hello from notes.txt
568a78ac9be8ab08ce84c90363cef53bab5d6aecf684e83cd44193dbad50cca6
```

## a quick question about a JSON file

For a ten-second question about a JSON file, skip the script: `cosmic
json` looks one value up. `cosmic json --exists '.users[1].email'
export.json` prints nothing and answers by its exit status (0 found, 1
not there); `cosmic json --keys export.json` lists the top-level keys,
sorted, or an array's length; `cosmic json --shape '.users' export.json`
summarizes what is inside; `cosmic json -r '.users[1].name' export.json`
prints a string without its quotes. The path is the `$.users[1].name`
style the JSON messages print, with indices counted from 1; quote it in
single quotes, as a shell expands `$` and `[1]`. The file is `-` or left
out to read standard input, so `curl ... | cosmic json '.items[1]'`
works. Numbers print as `Json.encode` writes them, so `1e2` reads
`100.0`. It is only a lookup, with no filters: to count or sum, use
`cosmic sql --from` (next section), and for anything else write the
script with `cosmic.json`. `cosmic help json` has the rest.

## a random id, token or number

`cosmic rand uuid` prints a UUID (`--v7` for a time-ordered one, by RFC 9562's
method 3 clock precision, `-n 5` for five, at most ten million); `cosmic rand token` a 32-byte base64url token; `cosmic rand int
1 6` a die roll; `cosmic rand pick file` or `shuffle file` draws lines. All
of it comes from the operating system's entropy, unless you name `--seed`
to replay `int`, `pick` or `shuffle`, which is not secret. `cosmic help
rand` has the rest.

## questions about a data file

A question about a data file -- what is in it, how many of these it
holds -- takes two steps, and neither is a script. Stop at the first that
answers:

1. Look it up with `cosmic json`: `cosmic json --shape export.json` says
   what is in the file, and `cosmic json '.users[1]' export.json` prints
   one value.
2. Count, filter, join and sum with `cosmic sql --from`, which loads the
   file as a table of an in-memory SQLite database and runs one
   read-only statement on it:

    cosmic sql --from accounts.json
    cosmic sql --from accounts.json 'SELECT type, sum(balance) FROM accounts GROUP BY type'
    cosmic sql --from accounts.json --from owners.jsonl 'SELECT who, balance FROM accounts JOIN owners USING (id)'
    curl ... | cosmic sql --from - --as ndjson 'SELECT count(*) FROM stdin'

With no statement, `--from` prints each table's row count, its columns
with the types stored in them, and one sample row, which is how to find
what to query. A table is named for its file's stem (`--from
name=file` names it), a `.jsonl` or `.ndjson` file is one row per line,
and `--at '$.data.rows'` takes the rows from the array at a path. Nested
objects and arrays are JSON text, so `json_extract(owner, '$.name')`
reaches into them; a boolean is 0 or 1. A column or table that does not
exist is answered with the ones that do. `cosmic help sql` has the rest.

## below cosmic.fs

`cosmic.fs` is built on `cosmic.sys`, the syscall table: one C function
per call, the same on Linux and on macOS. A call no module wraps, such
as `lstat`, is there. A failure returns nil, the error, and the errno.
`cosmic docs cosmic.sys` lists every call.

```teal
local syscalls = require("cosmic.sys")

assert(syscalls.mkdir(tmp .. "/made"))
local stat = assert(syscalls.lstat(tmp .. "/made"))
print(stat.kind)
```

```output
dir
```

## running another cosmic program

`cosmic.child` starts an executable from an exact path; it does not search
`PATH`. Its result reports how the process ended. Output is inherited unless
you redirect it to a caller-owned file descriptor, as this example does.

```teal file=greeter.tl
return function(argv: {string}): integer
  print("hello, " .. argv[1])
  return 0
end
```

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local output = tmp .. "/child-output"
local fd = assert(Fs.open_write(output))
-- This very cosmic, started past its launcher as `cosmic test` starts
-- a worker: the core it runs on, with what the launcher would hand it.
-- `{ Proc.executable(), ... }` starts it through the launcher instead,
-- which takes a shell.
local relaunch = assert(Proc.relaunch())
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = tmp .. "/greeter.tl"
argv[#argv + 1] = "cosmic"
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
local result, trouble = Child.run(argv,
  { env = env, fds = relaunch.fds, stdout = fd, timeout_ms = 5000 })
assert(Fs.close(fd))
if result == nil then error(trouble) end
local finished = assert(result)
assert(finished.ok and finished.code == 0)

local content = assert(Fs.read(output))
print(content:sub(1, -2))
print("exit " .. tostring(finished.code))
```

```output
hello, cosmic
exit 0
```

`Child.start` hands back a running child instead, and `Child.wait_any`
waits for the first of several to finish. When its timeout passes first it
answers `nil` and `""`: nothing finished, and nothing failed. A reason other
than `""` is a failure to report, never a message to read for its meaning.
The child's own `wait` then waits for it to finish, and answers how it
ended.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")

-- This cosmic again, past its launcher, running a chunk that sleeps
-- for half a second and exits 3.
local relaunch = assert(Proc.relaunch())
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = "-e"
argv[#argv + 1] = "require('cosmic.time').sleep_ns(500000000) return 3"
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
local sleeper <close> = assert(Child.start(argv, { env = env, fds = relaunch.fds }))
local done, trouble = Child.wait_any({ sleeper }, 10)
if done == nil and trouble ~= "" then error(trouble) end
print(done == nil and "still running" or "finished")
local ended = assert(sleeper:wait())
print("exit " .. tostring(ended.code))
```

```output
still running
exit 3
```

## ending early

A program's entry returns its exit status. Where returning is awkward,
`Proc.exit` ends the process at once with a status: it runs no finalizers
and never returns. This example declares no output, so it compiles and does
not run: running it would end the test that runs this guide.

```teal
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local config, trouble = Fs.read(tmp .. "/app.conf")
if config == nil then
  local _, _ = Fs.put(Fs.stderr, trouble .. "\n")
  Proc.exit(2)
end
```

## a number that starts at zero

Teal infers `integer` for `local peak = 0`, so a later `peak = peak + 1.5`
(or `peak = peak / 2`) is refused with `got number, expected integer`. When
the variable is a plain local declared from an integer literal, the message
names the fix. Write `local peak = 0.0`, or annotate `local peak: number = 0`,
for a variable that holds floats. A function declared `: number` may still
`return 0`: an integer is a number.
