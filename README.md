# cosmic-lua

A cosmopolitan Lua distribution with Teal support and bundled libraries.

## Overview

`cosmic-lua` is a single-file, self-contained Lua interpreter built on [Cosmopolitan Libc](https://github.com/jart/cosmopolitan) that runs on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD without requiring installation or dependencies.

It includes:
- **Lua 5.4**: Full Lua interpreter
- **Teal**: A typed dialect of Lua that compiles to Lua
- **cosmic library**: Core utilities for file operations, process spawning, HTTP fetching, and directory walking
- **Type definitions**: Complete type declarations for the Cosmopolitan Lua API

## Features

- **Actually Portable Executable**: Single binary runs on multiple platforms
- **No Installation Required**: Download and run
- **Teal Support**: Full integration with the Teal type checker and compiler
- **Self-Contained**: All dependencies bundled in the executable

## Installation

Download the latest release:

```bash
curl -L -o cosmic-lua https://github.com/whilp/cosmic/releases/latest/download/cosmic-lua
chmod +x cosmic-lua
```

## Usage

### Running Lua Scripts

```bash
./cosmic-lua script.lua
./cosmic-lua -e 'print("Hello, World!")'
```

### Using Teal

The Teal compiler is bundled and available via `tl.lua`:

```bash
./cosmic-lua /zip/tl.lua check myfile.tl
./cosmic-lua /zip/tl.lua run myfile.tl
```

### Cosmic Library

The cosmic library provides utilities for common tasks:

```lua
local cosmic = require("cosmic")
local spawn = require("cosmic.spawn")
local fetch = require("cosmic.fetch")
local fs = require("cosmic.fs")

-- Spawn a process
local result = spawn.run({"ls", "-la"})

-- Fetch a URL
local response = fetch.get("https://example.com")

-- Walk a directory
for _, path in ipairs(fs.collect(".", "%.lua$")) do
  print(path)
end
```

## Building from Source

Prerequisites:
- GNU Make
- Git
- Internet connection (to download dependencies)

Build the cosmic binary:

```bash
make cosmic
```

Run tests:

```bash
make test
```

Run type checking:

```bash
make check
```

Full CI pipeline:

```bash
make ci
```

## Development

The repository uses a module-based build system with:
- `lib/cosmic/`: Core cosmic library
- `lib/build/`: Build scripts for fetching and staging dependencies
- `3p/cosmos/`: Cosmopolitan Lua binary
- `3p/tl/`: Teal compiler
- `3p/teal-types/`: Teal type definitions

### Directory Structure

```
cosmic/
├── 3p/              # Third-party dependencies
├── lib/             # Library modules
│   ├── build/       # Build infrastructure
│   ├── checker/     # Type checking utilities
│   ├── cosmic/      # Core cosmic library
│   └── types/       # Type declarations
├── bin/             # Build scripts
├── Makefile         # Main build file
└── o/               # Build output directory (created during build)
```

## Documentation

### cosmo Package

Core Cosmopolitan Libc bindings and system interfaces.

| Module | Description |
|--------|-------------|
| [argon2](https://github.com/whilp/cosmic/blob/docs/cosmo/argon2.md) | Password hashing using the Argon2 algorithm. |
| [finger](https://github.com/whilp/cosmic/blob/docs/cosmo/finger.md) | TCP SYN packet fingerprinting. |
| [getopt](https://github.com/whilp/cosmic/blob/docs/cosmo/getopt.md) | Command-line option parsing. |
| [goodsocket](https://github.com/whilp/cosmic/blob/docs/cosmo/goodsocket.md) | Low-level socket programming with network constants. |
| [lsqlite3](https://github.com/whilp/cosmic/blob/docs/cosmo/lsqlite3.md) | SQLite3 database bindings. |
| [maxmind](https://github.com/whilp/cosmic/blob/docs/cosmo/maxmind.md) | MaxMind GeoIP database lookups. |
| [path](https://github.com/whilp/cosmic/blob/docs/cosmo/path.md) | File path manipulation utilities. |
| [re](https://github.com/whilp/cosmic/blob/docs/cosmo/re.md) | POSIX regular expression matching. |
| [unix](https://github.com/whilp/cosmic/blob/docs/cosmo/unix.md) | POSIX system interfaces and shared memory. |
| [zip](https://github.com/whilp/cosmic/blob/docs/cosmo/zip.md) | ZIP archive reading and writing. |

### cosmic Package

High-level utilities and tools built on top of cosmo.

| Module | Description |
|--------|-------------|
| [doc](https://github.com/whilp/cosmic/blob/docs/lib/cosmic/doc.md) | Extract documentation from Teal files and render as markdown. |
| [embed](https://github.com/whilp/cosmic/blob/docs/lib/cosmic/embed.md) | Embed files into cosmic executable. |
| [example](https://github.com/whilp/cosmic/blob/docs/lib/cosmic/example.md) | Go-style executable example testing. |
| [fetch](https://github.com/whilp/cosmic/blob/docs/lib/cosmic/fetch.md) | Structured HTTP fetch with optional retry. |
| [init](https://github.com/whilp/cosmic/blob/docs/lib/cosmic/init.md) | Cosmopolitan Lua utilities. |
| [spawn](https://github.com/whilp/cosmic/blob/docs/lib/cosmic/spawn.md) | Process spawning utilities. |
| [teal](https://github.com/whilp/cosmic/blob/docs/lib/cosmic/teal.md) | Teal compilation and type-checking. |
| [walk](https://github.com/whilp/cosmic/blob/docs/lib/cosmic/walk.md) | Directory tree walking utilities. |

## License

MIT License - See LICENSE file

## Links

- [Cosmopolitan Libc](https://github.com/jart/cosmopolitan)
- [Teal Language](https://github.com/teal-language/tl)
- [Lua](https://www.lua.org/)
