# Standard Library

the `cosmic.*` modules provide a typed, ergonomic layer over Cosmopolitan Libc bindings. import them as:

```teal
local json = require("cosmic.json")
local fs = require("cosmic.fs")
local sqlite = require("cosmic.sqlite")
```

## Module Index

### Core

| module | description |
|--------|-------------|
| `cosmic.json` | JSON encode/decode |
| `cosmic.fd` | file descriptor I/O: open/wrap handles, pipes |
| `cosmic.fs` | filesystem paths, stat, walk, mkdir, temp files |
| `cosmic.string` | trim, split, capitalize, starts_with |
| `cosmic.env` | environment variable get/set/unset/list |
| `cosmic.envd` | load environment variables from an embedded env.d directory |
| `cosmic.errno` | errno names, numbers, and error-string helpers |
| `cosmic.check` | assertion helpers for tests with auto-formatted failure messages |
| `cosmic.sys` | OS and architecture detection |
| `cosmic.time` | timestamps, sleep, clock, datetime breakdown |
| `cosmic.uuid` | UUIDv4 (random) and UUIDv7 (time-ordered) |

### Networking

| module | description |
|--------|-------------|
| `cosmic.fetch` | HTTP client with retry and structured results |
| `cosmic.net` | TCP/UDP/Unix domain sockets |
| `cosmic.ip` | IP address parsing, formatting, classification |
| `cosmic.url` | URL encoding, parsing, escaping |
| `cosmic.sse` | Server-Sent Events stream parser |
| `cosmic.poll` | poll(2) for I/O multiplexing |

### Data

| module | description |
|--------|-------------|
| `cosmic.sqlite` | SQLite with query/exec/transaction API |
| `cosmic.codec` | hex encoding/decoding, Lua serialization |
| `cosmic.compress` | zlib compress/decompress, raw deflate |
| `cosmic.html` | HTML entity escaping |
| `cosmic.zip` | ZIP archive reading and writing |

### Security

| module | description |
|--------|-------------|
| `cosmic.hash` | SHA-256 and Argon2 password hashing |
| `cosmic.rand` | cryptographic random bytes |
| `cosmic.sandbox` | one-call fail-closed facade over pledge, unveil, and landlock |
| `cosmic.pledge` | restrict system calls on OpenBSD and Linux |
| `cosmic.unveil` | restrict filesystem visibility on OpenBSD, or Linux via landlock |
| `cosmic.landlock` | Linux >=5.13 self-restricting filesystem sandbox |
| `cosmic.quicksand` | Linux namespace + allowlist proxy box primitives and declarative `Box` builder |

### Process

| module | description |
|--------|-------------|
| `cosmic.child` | spawn child processes with I/O control |
| `cosmic.proc` | current process: pid, exec, resource usage |
| `cosmic.signal` | signal handling, timers, sigsets |
| `cosmic.user` | user/group identity operations |
| `cosmic.shm` | shared memory with atomics and futexes |

### Terminal & Logging

| module | description |
|--------|-------------|
| `cosmic.tty` | terminal detection, window size, termios |
| `cosmic.syslog` | system logging with priority levels |
| `cosmic.getopt` | command-line option parsing |

### Text

| module | description |
|--------|-------------|
| `cosmic.re` | POSIX extended regular expressions |
| `cosmic.fuzzy` | fuzzy string matching (Levenshtein) |
| `cosmic.format` | Teal/Lua code formatter |

### Tooling

| module | description |
|--------|-------------|
| `cosmic.teal` | Teal compilation and type checking |
| `cosmic.doc` | extract docs from source; query the embedded doc index |
| `cosmic.embed` | create custom executables |
| `cosmic.example` | example runner |
| `cosmic.benchmark` | benchmark runner |
| `cosmic.testrun` | test execution and reporting |

## Error Handling Patterns

### Value + Error String (Primary)

most functions return `value, string` where the second return is an error message on failure:

```teal
local data, err = json.decode(input)
if not data then
  print("parse failed: " .. err)
  return
end
```

### Boolean + Error String

operations that succeed or fail:

```teal
local ok, err = db:exec("CREATE TABLE t (id INTEGER)")
if not ok then
  print("exec failed: " .. err)
end
```

### Result Records

complex operations return a record:

```teal
local result = fetch.fetch("https://example.com")
if result.ok then
  print(result.status, result.body)
else
  print(result.error)
end
```

### Infallible Functions

some functions cannot fail:

```teal
local hex = codec.encode_hex(data)        -- always succeeds
local compressed = compress.compress(data) -- always succeeds
local id = uuid.v4()                       -- always succeeds
```

## Common Patterns

### File I/O

```teal
local fs = require("cosmic.fs")
local fd = require("cosmic.fd")

-- read entire file
local content, err = fs.read("config.json")

-- write entire file
local ok, err = fs.write("output.txt", content)

-- low-level handle operations
local h, err = fd.open("file.dat", fd.O_RDONLY)
local data = h:read()
h:close()
```

### Filesystem

```teal
local fs = require("cosmic.fs")

fs.exists("/tmp/test")              -- true/false
fs.isdir("/tmp")                    -- true/false
fs.join("/usr", "local", "bin")     -- "/usr/local/bin"
fs.basename("/usr/local/bin")       -- "bin"
fs.dirname("/usr/local/bin")        -- "/usr/local"
fs.makedirs("/tmp/a/b/c")          -- create parents
fs.rmrf("/tmp/test")               -- recursive delete

-- walk directory tree
for path in fs.files("src", "*.tl") do
  print(path)
end
```

### SQLite

```teal
local sqlite = require("cosmic.sqlite")

local db, err = sqlite.open(":memory:")
db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
db:exec("INSERT INTO users (name) VALUES (?)", "alice")

for row in db:query("SELECT * FROM users WHERE name = ?", "alice") do
  print(row.id, row.name)
end

db:transaction(function(tx)
  tx:exec("INSERT INTO users (name) VALUES (?)", "bob")
  tx:exec("INSERT INTO users (name) VALUES (?)", "carol")
end)

db:close()
```

### HTTP

```teal
local fetch = require("cosmic.fetch")

local result = fetch.fetch("https://api.example.com/data")
if result.ok then
  local json = require("cosmic.json")
  local data = json.decode(result.body)
end
```

### Child Processes

```teal
local child = require("cosmic.child")

local result, err = child.run({"ls", "-la"})
if result then
  print(result.stdout)
  print(result.ok, result.code)
end
```

### Networking

```teal
local net = require("cosmic.net")

local sock, err = net.connect_tcp("127.0.0.1", 8080)
sock:send("GET / HTTP/1.0\r\n\r\n")
local response = sock:recv(4096)
sock:close()
```

### Sandboxing

`cosmic.quicksand.Box` composes the Linux namespace primitives,
landlock, pledge, and an allowlist HTTP proxy into a single declarative
policy + `run(argv)` call. Policy is a plain table, composable with
`Box.merge(base, over)`:

```teal
local quicksand = require("cosmic.quicksand")

local box = assert(quicksand.Box.new({
  fs   = { ro = {"/usr", "/etc/ssl/certs"}, rw = {"/tmp"} },
  net  = { allow = { ["api.example.com:443"] = {} } },
  proc = { no_new_privs = true, uid = 1000 },
  env  = { keep = {"PATH", "HOME"}, set = { CI = "1" } },
  cwd  = "/tmp",
}))
os.exit(assert(box:run({ "/usr/bin/bash", "-c", "make test" })))
```

`Box.new` validates shape and runs a capability preflight so
misconfiguration surfaces before any syscall. `run` forks a supervisor
that unshares `USER|NET|NS` (+`UTS` if `hostname` is set), writes
uid/gid maps, brings up loopback, optionally starts the allowlist
proxy (injecting `HTTP(S)_PROXY` into the workload env unless
`net.proxy_env == false`), then forks the workload which applies
landlock, no_new_privs, drop_privs, pledge, chdir and `execvpe(argv,
env)`. The returned integer is the workload's exit code (or
`128+signo` on signal).

For finer control the underlying primitives are still available:

- `cosmic.landlock` / `cosmic.pledge` / `cosmic.unveil` for
  self-restriction in the current process
- `cosmic.quicksand.netns` / `.proc` / `.proxy` for manually assembling
  a box

## Documentation

use the built-in docs system:

```bash
cosmic --docs json            # show cosmic.json docs
cosmic --docs sqlite.open     # show specific function
cosmic --docs "parse url"     # search docs
cosmic --examples json        # show examples
cosmic --help                 # list all modules
```

from the REPL:

```
$ cosmic -i
> help("json")
> help("fs.walk")
```
