# cosmic-lua

A portable Lua distribution with static typing, batteries included.

## Overview

cosmic-lua is a single-file Lua interpreter built on [Cosmopolitan Libc](https://github.com/jart/cosmopolitan) that runs on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD—no installation required.

**Key highlights:**

- **Portable**: One ~15MB executable runs on six operating systems
- **Type-safe**: Full [Teal](https://github.com/teal-language/tl) integration with static type checking
- **Batteries included**: 40+ modules for HTTP, SQLite, crypto, processes, networking, and more
- **Self-documenting**: Query embedded API docs with `--docs`

## Installation

```bash
curl -L -o cosmic-lua https://github.com/whilp/cosmic/releases/latest/download/cosmic-lua
chmod +x cosmic-lua
```

## Quick Start

```bash
# Run scripts
./cosmic-lua script.lua           # Lua script
./cosmic-lua script.tl            # Teal script (compiled on-the-fly)
./cosmic-lua -e 'print("hi")'     # Inline code

# Teal type checking
./cosmic-lua --check file.tl      # Type-check without running
./cosmic-lua --compile file.tl    # Compile to Lua (stdout)

# Documentation
./cosmic-lua --docs fetch         # Search embedded docs
./cosmic-lua --help               # Show all modules
```

## Example Code

### HTTP + JSON

```lua
local fetch = require("cosmic.fetch")
local json = require("cosmic.json")

local resp = fetch.get("https://api.example.com/data")
if resp.ok then
    local data = json.decode(resp.body)
    print(data.name)
end
```

### Process Spawning

```lua
local child = require("cosmic.child")

local h = child.spawn({"ls", "-la"})
local status, stdout = h:read()
print(stdout)
```

### SQLite Database

```lua
local sqlite = require("cosmic.sqlite")

local db <close> = sqlite.open("app.db")
db:exec("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)")
db:exec("INSERT INTO kv VALUES (?, ?)", "key", "value")

for row in db:query("SELECT * FROM kv") do
    print(row.k, row.v)
end
```

### File Operations

```lua
local fs = require("cosmic.fs")

-- Walk directory with glob pattern
for path in fs.walk(".", "*.tl") do
    print(path)
end

-- Path manipulation
local p = fs.join("/home", "user", "file.txt")
print(fs.basename(p))  -- file.txt
print(fs.dirname(p))   -- /home/user
```

### Command-line Arguments

```lua
local getopt = require("cosmic.getopt")

local opts, args = getopt.parse(arg, "hv", {"help", "verbose"})
if opts.help then
    print("Usage: script [options] <args>")
end
```

## Module Overview

### Core

| Module | Description |
|--------|-------------|
| `cosmic.fetch` | HTTP client with retry, redirects, timeouts |
| `cosmic.json` | JSON encode/decode |
| `cosmic.sqlite` | SQLite database with prepared statements |
| `cosmic.child` | Process spawning with I/O capture |
| `cosmic.fs` | Filesystem: paths, walking, file operations |
| `cosmic.getopt` | Command-line argument parsing |

### Networking

| Module | Description |
|--------|-------------|
| `cosmic.net` | TCP/UDP sockets, Unix domain sockets |
| `cosmic.url` | URL parsing and encoding |
| `cosmic.ip` | IP address parsing and formatting |

### Security

| Module | Description |
|--------|-------------|
| `cosmic.hash` | SHA-256, Argon2 password hashing |
| `cosmic.rand` | Cryptographically secure random bytes |
| `cosmic.sandbox` | Process sandboxing with pledge/unveil |

### Data Processing

| Module | Description |
|--------|-------------|
| `cosmic.codec` | Base64, hex encoding |
| `cosmic.compress` | zlib compression/decompression |
| `cosmic.zip` | ZIP archive read/write |
| `cosmic.html` | HTML escaping |
| `cosmic.re` | POSIX regular expressions |

### System

| Module | Description |
|--------|-------------|
| `cosmic.proc` | Process info, signals, daemonization |
| `cosmic.env` | Environment variables |
| `cosmic.time` | Timestamps, sleep, time formatting |
| `cosmic.signal` | Signal handling |
| `cosmic.sys` | System info (hostname, uname) |
| `cosmic.user` | User/group information |
| `cosmic.uuid` | UUID v4 (random) and v7 (time-ordered) |
| `cosmic.shm` | Shared memory and IPC |
| `cosmic.tty` | Terminal operations |
| `cosmic.syslog` | System logging |
| `cosmic.io` | File I/O operations |

Use `./cosmic-lua --docs <module>` to explore any module's API.

## Building from Source

```bash
make staged    # Fetch dependencies
make cosmic    # Build the binary
make check     # Teal type checking
make test      # Run tests
make ci        # Full CI pipeline
```

## Project Structure

```
cosmic/
├── 3p/              # Third-party: cosmos binary, teal compiler
├── lib/
│   ├── cosmic/      # Library modules (40+)
│   ├── types/       # Teal type definitions
│   ├── build/       # Build infrastructure
│   └── docs/        # Documentation generation
├── Makefile         # Build orchestration
└── GOALS.md         # Project goals and roadmap
```

## Design Principles

- **Type safety**: All APIs have complete Teal type definitions
- **Explicit errors**: Functions return `(value, error)` instead of throwing
- **Resource cleanup**: File handles use `__close` for automatic cleanup
- **No silent failures**: Clear error messages at API boundaries

## License

MIT License - See LICENSE file

## Links

- [Cosmopolitan Libc](https://github.com/jart/cosmopolitan)
- [Teal Language](https://github.com/teal-language/tl)
- [Lua](https://www.lua.org/)
