# quickstart

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

cosmic is one executable: the Lua runtime, the Teal compiler, and a
standard library, `cosmic.*`, for the everyday things a script needs.
This guide uses several of those modules and shows what they do. To
start a project of your own, see the guide `cosmic docs project`.

## hashing bytes

[`cosmic.hash`] turns a string into its SHA-256 digest, as 64 lowercase
hex characters.

```teal
local Hash = require("cosmic.hash")

print(Hash.hex_sha256("cosmic"))
```

```output
01307b41e7ff0bb31cca03fb7ff5bea9fdb3dd83afaca63d588a0c07e7ae98b8
```

## reading a file back

[`cosmic.fs`] reads and writes files. [`Fs.mkdtemp`] makes a fresh directory
to work in, [`Fs.write`] puts a file in it, and [`Fs.read`] reads it back.

```teal
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")

local dir = assert(Fs.mkdtemp("quickstart-"))
assert(Fs.write(dir .. "/notes.txt", "hello from notes.txt"))
local content, trouble = Fs.read(dir .. "/notes.txt")
if content == nil then
  error(trouble)
end
print(content)
print(Hash.hex_sha256(content))
assert(Fs.remove_tree(dir))
```

```output
hello from notes.txt
568a78ac9be8ab08ce84c90363cef53bab5d6aecf684e83cd44193dbad50cca6
```

## a quick question about a JSON file

For a ten-second question about a JSON file, skip the script: `cosmic
json` looks one value up. `cosmic json --exists '$.users[0].email'
export.json` prints nothing and answers by its exit status (0 found, 1
not there); `cosmic json --keys export.json` lists the top-level keys,
sorted, or an array's length; `cosmic json --shape '$.users' export.json`
summarizes what is inside; `cosmic json -r '$.users[0].name' export.json`
prints a string without its quotes. The path is a JSONPath query: `$`
first, then names and indices counted from 0 (`[-1]` is the last), as
JSON Pointer counts them in the messages; quote it in single quotes, as
a shell expands `$` and `[0]`. The file is `-` or left out to read
standard input, so `curl ... | cosmic json '$.items[0]'` works. Numbers
print as [`Json.encode`] writes them, so `1e2` reads `100.0`.

When you do not know where a value lives, list them all: `cosmic json
--flat export.json` prints every leaf as a `path = value` line, keys
sorted, and `cosmic json --flat export.json | grep -i email` finds the
one you want, say `$.users[1].contact.email = "bo@example.com"`. That
path is one `cosmic json` reads, so paste it back in single quotes:
`cosmic json '$.users[1].contact' export.json` shows what is around it.
A key that is not a word prints as `$["a key"]`; one holding `'` needs
`'\''` inside the shell's single quotes. A `*` stands for every
member or element, and `..` for any depth: `cosmic json '$.users[*].name'
export.json` prints each user's name as such a line, `cosmic json -r
'$..email' export.json` every email in the file, bare (a string with a
newline in it takes more than one line), and `cosmic json
--exists '$..error' export.json` asks whether any `error` key is there.
`--keys` and `--shape` take one path, not a query of `*` or `..`.
JSONPath filters, slices and unions are refused, on purpose: it is only
a lookup, and `grep` over `--flat` covers the simple cases. To count or
sum, use `cosmic sql --from` (next section); for anything else write
the script with `cosmic.json`: [`Json.decode`] the file and walk the
value in Lua, or look a path up with [`Json.get`] and [`Json.select`].
`cosmic help json` has the rest.

## a random id, token or number

`cosmic rand uuid` prints a UUID (`--v7` for a time-ordered one, by RFC 9562's
method 3 clock precision, `-n 5` for five, at most ten million); `cosmic rand token` a 32-byte base64url token; `cosmic rand int
1 6` a die roll; `cosmic rand pick file` or `shuffle file` draws lines. All
of it comes from the operating system's entropy, unless you name `--seed`
to replay `int`, `pick` or `shuffle`, which is not secret. `cosmic help
rand` has the rest.

## questions about a data file

A question about a data file -- what is in it, how many of these it
holds -- takes three steps, and none is a script. Stop at the first that
answers:

1. Look it up with `cosmic json`: `cosmic json --shape export.json` says
   what is in the file, and `cosmic json '$.users[0]' export.json` prints
   one value.
2. Find where something is with `cosmic json --flat export.json | grep
   needle`, and paste the path it prints back into `cosmic json`.
3. Count, filter, join and sum with `cosmic sql --from`, which loads the
   file as a table of an in-memory SQLite database and runs one
   read-only statement on it:

    cosmic sql --from accounts.json
    cosmic sql --from accounts.json 'SELECT type, sum(balance) FROM accounts GROUP BY type'
    cosmic sql --from accounts.json --from owners.jsonl 'SELECT who, balance FROM accounts JOIN owners USING (id)'
    cosmic sql --from sales.csv 'SELECT region, sum(amount) FROM sales GROUP BY region'
    curl ... | cosmic sql --from - --as ndjson 'SELECT count(*) FROM stdin'

With no statement, `--from` prints each table's row count, its columns
with the types stored in them, and one sample row, which is how to find
what to query. A table is named for its file's stem (`--from
name=file` names it), a `.jsonl` or `.ndjson` file is one row per line,
and `--at '$.data.rows'` takes the rows from the array at a path. A
`.csv` file (`.tsv` or `.tab` for tabs) takes its columns from the
header line (`SELECT *` keeps that order), and a record with another
number of fields is refused, naming its line. A blank line is skipped,
except in a one-column file, where one before the last record is an
empty cell (a final empty cell is written `""` to be kept). Its cells are typed by one rule: a plain number
(`-12`, `3.5`, `1e5`) is an integer or a real, an empty cell is NULL,
and anything else is text, so a ZIP code like `02134` and `007` keep
their zeros. `--raw` after the `--from` keeps every cell text, and a CSV
joins a JSON file on any column. Read standard input with `--from -
--as csv`. Nested
objects and arrays are JSON text, so `json_extract(owner, '$.name')`
reaches into them; a boolean is 0 or 1. A column or table that does not
exist is answered with the ones that do. `cosmic help sql` has the rest.

`cosmic fetch <url>` is a small curl: it prints the body, fails on a
non-2xx, and takes `-o file` and `--sha256 hex`, so `cosmic fetch <url> |
cosmic json '$.items'` works. A URL may carry its digest, as pip's do:
`cosmic fetch -o tool.tgz https://host/tool.tgz#sha256=<hex>` renames the file into place only if it matches. `cosmic help fetch` has the rest.

## the digest of a file

`cosmic hash [--sha512 | --sha1 | --md5 | ...] [<file>|-]...` prints `sha256sum`'s `<hex>  <name>` lines, the same on every platform (`sha256sum` and `shasum -a 256` differ), streaming each file; `--check sums.txt` verifies a list (`name: OK` or `FAILED`, exit 1 on any failure), and `--hmac-file key.bin` makes each digest an HMAC without the key in `ps`. `cosmic help hash` has the rest.

## bytes to text and back

`cosmic codec hex|base64|base64url [-d] [file|-]` encodes a file or
standard input on one line (`--wrap N` wraps it; GNU base64's 76 is not
the default) and with `-d` decodes it, ignoring whitespace and refusing
a bad character or padding with exit 2 and its byte offset: `printf hi
| cosmic codec base64` prints `aGk=`. base64url is unpadded, as JWTs
write it; `--lenient` accepts the other padding. It prints no verdict
line.

## a quick look inside an archive

`cosmic archive list release.tar.gz` prints one entry per line (path, size,
mode, type), and `--json` an array of objects for `cosmic json` or
`cosmic sql --from -`; `cosmic archive extract release.zip -C out [member...]` unpacks
all or some of it, refusing a path that escapes `out` and a file it would
overwrite (unless `--force`) -- only that and a missing member write
nothing; an unsafe entry stops extraction after the entries before it, which
stay written; `cosmic archive create out.tar.gz dir
--reproducible` packs a tree (fixed times, file modes kept), as a zip, a gzip tar or a plain tar, by its name. The format is read from
the file's bytes, not its name; `-` reads standard input. `cosmic help archive`
has the rest.

## a quick question about a time

For a clock or calendar question, `cosmic time` answers the same on every
host, where GNU and BSD `date` differ, with zones from the binary's own tz
database. `cosmic time now --zone Asia/Tokyo`; `cosmic time convert
2026-03-08T12:00Z --to America/New_York`; `cosmic time between 2026-01-01
2026-09-28 --days`; `cosmic time add 2026-01-31 1mo --clamp` (a duration is
`1y2mo3d4h5m6s`, negative with a leading `-`). A time is RFC 3339, a date,
a local `2026-03-08T02:30` (read in `--from`; a gap or overlap resolved by
`--disambiguate`) or `@<epoch>`. `--json` prints the fields. `cosmic help
time` has the rest.

## looking up a symbol and where it is used

`cosmic docs cosmic.hash` lists what a module offers: each function's
signature, with how many places use it and how many examples it has, ahead
of the rest of its prose. `cosmic docs hex_sha256` (or [`Hash.hex_sha256`])
shows one symbol, with its doc comment and its examples. Words search the
documentation instead, so `cosmic docs sha256 hex` finds the same function
when you do not know its name, the first five matches whole and the rest a
line each. Several qualified names, such as `cosmic docs Fs.read Fs.write`,
are each looked up in turn. With no argument, `cosmic docs` lists every
module, and `cosmic docs cosmic` the standard library's. Then
`cosmic uses Hash.hex_sha256` prints each `file:line` that refers to it,
to see how others call it before you do:

    $ cosmic docs cosmic.hash
    cosmic.hash (cosmic/hash.tl)
      Content hashes and message authentication, over the vendored
      mbedtls.
    ...
      function Hash.hex_sha256(data: string): string  (91 uses, 2 examples)
    ...
    $ cosmic uses Hash.hex_sha256
    mylib/report_test.tl:40: cosmic.hash hex_sha256
    myapp/main.tl:210: cosmic.hash hex_sha256
    ...

`cosmic help docs` and `cosmic help uses` have the rest.

## a program held to what you grant it

`cosmic sandbox --system --read . -- ls -l` runs `ls` held to nothing but
what you name: it reads this directory and starts, and a path you did not
grant, a program you did not run and a call it did not promise all fail. A
policy that this host cannot meet is not run in part: the start fails
(exit 125) and says what is missing. `--read`, `--run` and `--write` grant
a path; `--path rwxc:work` names the letters; `--promise fork` lets it start
processes; `--isolate file` gives it a root of its own; `--tmp`, `--env` and
`--set-env` shape its environment; `--timeout` and the limits bound what it
spends. Everything after the program is the program's own, so `cosmic
sandbox --system -- sh --version` asks `sh`. It exits with the program's
status. `cosmic help sandbox` has the rest, and `cosmic docs
cosmic.sandbox` the policy these options write.

`--cosmic` grants cosmic itself, so a script of yours runs held the same
way: `cosmic sandbox --cosmic --read . -- cosmic convert.tl in.csv out.json`
reads its words from the function it returns (`argv[1]`, `argv[2]`), runs
as `--standalone` does and writes nothing beside it; add a `--write` for
the output it makes. Standalone, it finds `cosmic.*` modules only: a script
with modules of its own beside it takes `--set-env COSMIC_STANDALONE=0
--write .`, which builds the tree around it into `o/`.

`--closure` holds a script to the modules it needs and nothing of this
program's own file: `cosmic sandbox --closure -- cosmic convert.tl in.csv
out.json` compiles `convert.tl` here, seals it with the `cosmic.*` modules
it requires by name, and runs it on that, so a `require` of anything else
fails; a module of your own beside the script is refused before the child
starts, and a `pcall(require, ...)` or computed name is not followed.
`--database PATH` runs a file [`Store.seal`] wrote, and `--modules a,b`
seals exactly those modules (the first its main) from this program's store;
the three are exclusive. The database a run seals is removed when it ends.

## below cosmic.fs

[`cosmic.fs`] is built on [`cosmic.sys`], the syscall table: one C function
per call, the same on Linux and on macOS. A call no module wraps, such
as `lstat`, is there. A failure returns nil, the error, and the errno.
`cosmic docs cosmic.sys` lists every call.

```teal
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local dir = assert(Fs.mkdtemp("quickstart-"))
assert(sys.mkdir(dir .. "/made"))
local stat = assert(sys.lstat(dir .. "/made"))
print(stat.kind)
assert(Fs.remove_tree(dir))
```

```output
dir
```

## running another cosmic program

[`cosmic.child`] starts an executable from an exact path; it does not search
`PATH`. Its result reports how the process ended. Output is inherited unless
you redirect it to a caller-owned file descriptor, as this example does.
It writes a small program, `greeter.tl`, and runs it.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

local dir = assert(Fs.mkdtemp("quickstart-"))
assert(Fs.write(dir .. "/greeter.tl", [[
return function(argv: {string}): integer
  print("hello, " .. argv[1])
  return 0
end
]]))
local output = dir .. "/child-output"
local fd = assert(Fs.open_write(output))
-- This very cosmic, started past its launcher as `cosmic test` starts
-- a worker: the core it runs on, with what the launcher would hand it.
-- `{ Proc.executable(), ... }` starts it through the launcher instead,
-- which takes a shell.
local relaunch = assert(Proc.relaunch())
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = dir .. "/greeter.tl"
argv[#argv + 1] = "cosmic"
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
local result, trouble = Child.run(argv,
  { env = env, fds = relaunch.fds, stdout = fd, timeout_ns = Clock.seconds(5) })
assert(Fs.close(fd))
if result == nil then error(trouble) end
local finished = assert(result)
assert(finished.ok and finished.code == 0)

local content = assert(Fs.read(output))
print(content:sub(1, -2))
print("exit " .. tostring(finished.code))
assert(Fs.remove_tree(dir))
```

```output
hello, cosmic
exit 0
```

[`Child.start`] hands back a running child instead, and [`Child.wait_any`]
waits for the first of several to finish. When its timeout passes first it
answers `nil` and [`Poll.TIMEOUT`]: nothing finished, and nothing failed. Any
other reason beside a `nil` is a failure to report, never a message to read
for its meaning.
The child's own `wait` then waits for it to finish, and answers how it
ended.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

-- This cosmic again, past its launcher, running a chunk that sleeps
-- for half a second and exits 3.
local relaunch = assert(Proc.relaunch())
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = "-e"
argv[#argv + 1] = "require('cosmic.clock').sleep_ns(500000000) return 3"
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
local sleeper <close> = assert(Child.start(argv, { env = env, fds = relaunch.fds }))
local done, trouble = Child.wait_any({ sleeper }, Clock.ms(10))
if done == nil and trouble ~= Poll.TIMEOUT then error(trouble) end
print(done == nil and "still running" or "finished")
local ended = assert(sleeper:wait())
print("exit " .. tostring(ended.code))
```

```output
still running
exit 3
```

## closing what a block opened

`local sleeper <close> = assert(Child.start(...))`, above, closes the
child when the block ends, however it ends -- by its last line, a
`return` or an error: `<close>` calls its type's `__close`, which ends
a child still running. An opener answers `Handle | nil` and a reason,
and the compiler refuses `<close>` on a type that may be nil, so
`assert` narrows it first, raising the reason when there is no handle.
The same line holds a [`Signal.guard`], a [`cosmic.net`] socket or an
[`Http.open`] response. A descriptor from [`Fs.open_read`] is an
integer, which `<close>` cannot hold: [`Fs.close`] closes it, and
[`Fs.read`] reads a whole file without one.

## ending early

A program's entry returns its exit status. Where returning is awkward,
[`Proc.exit`] ends the process at once with a status: it runs no finalizers
and never returns. This example declares no output, so it compiles and does
not run: running it would end the test that runs this guide.

```teal
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local config, trouble = Fs.read("app.conf")
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

[`Child.start`]: ../../cosmic/child.tl
[`Child.wait_any`]: ../../cosmic/child.tl
[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.fs`]: ../../cosmic/fs.tl
[`cosmic.hash`]: ../../cosmic/hash.tl
[`cosmic.net`]: ../../cosmic/net.tl
[`cosmic.sys`]: ../../core/syscalls.h
[`Fs.close`]: ../../cosmic/fs.tl
[`Fs.mkdtemp`]: ../../cosmic/fs.tl
[`Fs.open_read`]: ../../cosmic/fs.tl
[`Fs.read`]: ../../cosmic/fs.tl
[`Fs.write`]: ../../cosmic/fs.tl
[`Hash.hex_sha256`]: ../../cosmic/hash.tl
[`Http.open`]: ../../cosmic/http/init.tl
[`Json.decode`]: ../../cosmic/json.tl
[`Json.encode`]: ../../cosmic/json.tl
[`Json.get`]: ../../cosmic/json.tl
[`Json.select`]: ../../cosmic/json.tl
[`Poll.TIMEOUT`]: ../../cosmic/poll.tl
[`Proc.exit`]: ../../cosmic/proc.tl
[`Signal.guard`]: ../../cosmic/signal.tl
[`Store.seal`]: ../../cosmic/store.tl
