# quickstart

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

cosmic is one executable. It holds the Lua runtime, the Teal compiler,
and a standard library, `cosmic.*`, for the everyday work a script
does. This guide shows a few modules and verbs, with one example each.
`cosmic help <verb>` and `cosmic docs <module>` have the rest. To start
a project of your own, see `cosmic docs project`.

## running a file

Write a Teal file and give it to `cosmic`.

```teal file=hello.tl
print("hello")
```

```sh
cosmic hello.tl
```

```output
hello
```

`cosmic -e '<chunk>'` runs a line of Teal with no file.

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

[`Hash.hex_file`] hashes a file in chunks, so a large file is never read
whole. At the shell, `cosmic hash <file>` prints the same lines as
`sha256sum`, on every platform.

## reading a file back

[`cosmic.fs`] reads and writes files. [`Fs.mkdtemp`] makes a fresh
directory, [`Fs.write`] puts a file in it, and [`Fs.read`] reads it back.

```teal
local Fs = require("cosmic.fs")

local dir = assert(Fs.mkdtemp("quickstart-"))
assert(Fs.write(dir .. "/notes.txt", "hello from notes.txt"))
local content, trouble = Fs.read(dir .. "/notes.txt")
if content == nil then
  error(trouble)
end
print(content)
assert(Fs.remove_tree(dir))
```

```output
hello from notes.txt
```

## a quick question about a JSON file

`cosmic json` looks up a value in a JSON file, with no script. The path
is a JSONPath query. Put it in single quotes, so the shell leaves its
`$` and `[0]` alone.

```teal file=export.json
{"users": [{"name": "Ada", "email": "ada@example.com"},
           {"name": "Bo", "contact": {"email": "bo@example.com"}}]}
```

```sh
cosmic json -r '$.users[0].name' export.json
cosmic json -r '$..email' export.json
cosmic json --flat export.json
```

```output
Ada
ada@example.com
bo@example.com
$.users[0].email = "ada@example.com"
$.users[0].name = "Ada"
$.users[1].contact.email = "bo@example.com"
$.users[1].name = "Bo"
```

`-r` prints a string without its quotes. `..` finds a key at any depth.
`--flat` prints every value with its path, and you can paste a path back
into `cosmic json`. `cosmic help json` has the rest. A program reads JSON
with [`Json.decode`] and [`Json.get`].

## questions about a data file

`cosmic sql --from` loads a JSON, CSV or NDJSON file as a table and runs
one read-only SQL statement on it.

```teal file=sales.csv
region,amount
east,10
west,5
east,7
```

```sh
cosmic sql --from sales.csv 'SELECT region, sum(amount) AS total FROM sales GROUP BY region'
```

```output
region	total
east	17
west	5
```

The table is named for the file. With no statement, `cosmic sql --from
sales.csv` lists each table's columns and a sample row. `cosmic help sql`
has the rest.

`cosmic fetch <url>` gets a URL and prints the body, so `cosmic fetch
<url> | cosmic json '$.items'` works. `cosmic help fetch` has the rest.

## looking up a symbol and where it is used

`cosmic docs` shows the documentation of the standard library, offline.

```sh
cosmic docs cosmic.hash
cosmic docs Hash.hex_sha256
cosmic docs sha256 hex
cosmic uses Hash.hex_sha256
```

The first command lists what a module offers. The second shows one symbol,
with its examples. The third searches by words, for when you do not
know the name. `cosmic uses` prints each place that refers to a symbol,
so you can see how others call it. `cosmic help docs` has the rest.

## a program held to what you grant it

`cosmic sandbox` runs a program that can reach only what you grant.

```text
cosmic sandbox --system --read . -- ls -l
```

Here `ls` can read this directory, and `--system` grants what a host
program needs to start. A path you did not grant fails. If this host
cannot enforce the policy, nothing runs, and the command says what is
missing. `--cosmic` grants what cosmic itself needs, to run a script of
yours the same way. `cosmic help sandbox` has the rest.

## running another cosmic program

[`cosmic.child`] starts an executable by its exact path. It does not
search `PATH`. This example writes a small program, `greeter.tl`, and
runs it with the same cosmic that runs the example.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

local dir = assert(Fs.mkdtemp("quickstart-"))
assert(Fs.write(dir .. "/greeter.tl", [[
return function(argv: {string}): integer
  print("hello, " .. (argv[1] or "world"))
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
if result == nil then error(tostring(trouble)) end
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

[`Child.start`] returns a running child instead, and [`Child.wait_any`]
waits for the first of several to finish. When the timeout passes
first, it returns `nil` and a [`Failure`] of kind "timeout". A Failure
of any other kind is a failure to report.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

-- This cosmic again, past its launcher, running a chunk that sleeps
-- for half a second and exits 3.
local relaunch = assert(Proc.relaunch())
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = "-e"
argv[#argv + 1] = "local _, _ = require('cosmic.clock').sleep(500000000) return 3"
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
local sleeper <close> = assert(Child.start(argv, { timeout_ns = Child.FOREVER, env = env, fds = relaunch.fds }))
local done, trouble = Child.wait_any({ sleeper }, Clock.ms(10))
if done == nil and trouble.kind ~= "timeout" then error(tostring(trouble)) end
print(if done == nil then "still running" else "finished" end)
local ended = assert(sleeper:wait())
print("exit " .. tostring(ended.code))
```

```output
still running
exit 3
```

`local sleeper <close> = ...` ends the child when the block ends,
whatever way it ends. `<close>` takes no value that may be nil, so
`assert` comes first. `cosmic docs language` says more about `<close>`.

## ending early

A program's entry returns its exit status. Where returning is awkward,
[`Proc.exit`] ends the process at once with a status. It runs no
finalizers and never returns. This example has no output block, so the
guide's test compiles it and does not run it: running it would end the
test.

```teal
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local config, why = Fs.read("app.conf")
if config == nil then
  print(tostring(why))
  Proc.exit(2)
end
```

## more quick tools

Each of these verbs does one job at the shell. `cosmic help <verb>` has
its options.

- `cosmic rand uuid` prints a UUID, and `cosmic rand token` a random
  token. A program draws one with [`Rand.uuid`].
- `cosmic time convert 2026-03-08T12:00Z --zone America/New_York` converts
  a time. Its answers are the same on every host.
- `cosmic codec base64 <file>` encodes a file, and `-d` decodes it.
- `cosmic archive list release.tar.gz` lists an archive, and `cosmic
  archive extract` unpacks one safely.
- `cosmic qr https://example.com/` prints a QR code in the terminal.
  [`Qr.text`] draws one in a program.
- `cosmic acme issue` gets a certificate from Let's Encrypt. A program
  uses [`Acme.client`].
- `cosmic tailscale status` lists this machine's Tailscale node and its
  peers, with no `tailscale` binary. A program uses
  [`Tailscale.connect`].
- `cosmic mcp tools -- server.tl` starts an MCP server and lists its
  tools, and `cosmic mcp call add '{"a":1}' -- server.tl` runs one.
  [`McpServer.Instance.main`] serves one from a program.
- `cosmic compile file.tl` prints the Lua that a Teal file compiles to.
- `cosmic agent ask 'what does this repository do?'` asks Claude about
  this directory, with its tools held to a sandbox.

## where to look next

- `cosmic docs cosmic` lists every module of the standard library.
- [`cosmic.sys`] is the syscall table below [`cosmic.fs`], one C function
  per call, for a call no module wraps.
- `cosmic docs language` covers the type checker's rules.

[`Acme.client`]: ../../cosmic/acme.tl
[`Child.start`]: ../../cosmic/child/init.tl
[`Child.wait_any`]: ../../cosmic/child/init.tl
[`cosmic.child`]: ../../cosmic/child/init.tl
[`cosmic.fs`]: ../../cosmic/fs.tl
[`cosmic.hash`]: ../../cosmic/hash.tl
[`cosmic.sys`]: ../../core/syscalls.h
[`Failure`]: ../../cosmic/failure.tl
[`Fs.mkdtemp`]: ../../cosmic/fs.tl
[`Fs.read`]: ../../cosmic/fs.tl
[`Fs.write`]: ../../cosmic/fs.tl
[`Hash.hex_file`]: ../../cosmic/hash.tl
[`Json.decode`]: ../../cosmic/json.tl
[`Json.get`]: ../../cosmic/json.tl
[`McpServer.Instance.main`]: ../../cosmic/mcp/server.tl
[`Proc.exit`]: ../../cosmic/proc.tl
[`Qr.text`]: ../../cosmic/qr.tl
[`Rand.uuid`]: ../../cosmic/rand.tl
[`Tailscale.connect`]: ../../cosmic/tailscale.tl
