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
| `cosmic.io` | file descriptor I/O, pipes, slurp/spit |
| `cosmic.fs` | filesystem paths, stat, walk, mkdir, temp files |
| `cosmic.string` | trim, split, capitalize, starts_with |
| `cosmic.env` | environment variable get/set/unset/list |
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
| `cosmic.crypto` | symmetric encryption with SHA256-CTR+HMAC-SHA256 and Argon2 key derivation |
| `cosmic.hash` | SHA-256 and Argon2 password hashing |
| `cosmic.rand` | cryptographic random bytes |
| `cosmic.sandbox` | pledge/unveil security restrictions |

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
| `cosmic.doc` | extract docs from Teal source |
| `cosmic.docs` | query embedded documentation |
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
local result = fetch.get("https://example.com")
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
local cio = require("cosmic.io")

-- read entire file
local content, err = cio.slurp("config.json")

-- write entire file
local ok, err = cio.spit("output.txt", content)

-- low-level fd operations
local fd, err = cio.open("file.dat", cio.O_RDONLY)
local data = cio.read(fd)
cio.close(fd)
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

local result = fetch.get("https://api.example.com/data")
if result.ok then
  local json = require("cosmic.json")
  local data = json.decode(result.body)
end
```

### Child Processes

```teal
local child = require("cosmic.child")

local handle, err = child.spawn({"ls", "-la"})
if handle then
  local ok, stdout = handle:read()
  local status = handle:wait()
  print(stdout)
end
```

### Networking

```teal
local net = require("cosmic.net")
local ip = require("cosmic.ip")

local sock, err = net.tcp()
sock:connect(ip.parse("127.0.0.1"):int(), 8080)
sock:send("GET / HTTP/1.0\r\n\r\n")
local response = sock:recv(4096)
sock:close()
```

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
