# Modules

all modules live in `lib/cosmic/` and are imported as `cosmic.*`. use these instead of the raw `cosmo.*` C bindings.

## Module List

| module | description |
|--------|-------------|
| benchmark | benchmark runner with `Benchmark_*` functions |
| child | child process spawning with I/O control |
| codec | hex encoding/decoding, Lua serialization |
| compress | zlib compression/decompression |
| doc | extract docs from Teal source files |
| docs | query embedded documentation index |
| embed | create custom executables with embedded files |
| env | environment variable get/set/unset |
| envd | load environment variables from embedded env.d directory |
| example | example runner with `Example_*` functions |
| fetch | HTTP client with retry support |
| format | Teal/Lua code formatter |
| fs | filesystem: paths, stat, walk, mkdir, symlink, tmp |
| fuzzy | fuzzy string matching (Levenshtein distance) |
| getopt | command-line option parsing (short + long opts) |
| hash | SHA-256 digest and Argon2 password hashing |
| html | HTML escaping |
| io | file descriptor I/O, pipes, slurp/barf |
| ip | IP address parsing, formatting, classification |
| json | JSON encode/decode |
| net | TCP/UDP/Unix sockets |
| poll | poll(2) wrapper for I/O multiplexing |
| proc | current process: pid, exec, resource usage, is_main() |
| rand | cryptographic random bytes |
| re | POSIX extended regular expressions |
| sandbox | pledge and unveil for security sandboxing |
| shm | shared memory with atomic ops and futexes |
| signal | signal handling, timers, sigsets |
| sqlite | SQLite with ergonomic query/exec/transaction API |
| sse | Server-Sent Events parser |
| string | trim, split, capitalize, starts_with, etc. |
| sys | OS/architecture detection |
| syslog | system logging |
| teal | Teal compilation and type checking |
| testrun | test execution and reporting |
| time | timestamps, sleep, clock, datetime |
| tty | terminal detection, window size, termios |
| url | URL encoding, parsing, escaping |
| user | user/group identity |
| uuid | UUIDv4 and UUIDv7 generation |
| zip | ZIP archive reading and writing |

## cosmo vs cosmic

`cosmo.*` modules are raw C bindings from Cosmopolitan Libc — low-level and untyped from Teal's perspective. `cosmic.*` modules are the typed wrappers with error handling and documentation.

- **library internals** (`lib/cosmic/*.tl`): use `cosmo.*` to implement wrappers
- **everything else** (examples, tests, scripts): always use `cosmic.*`

common mappings:

| instead of | use |
|------------|-----|
| `cosmo.Barf(path, data)` | `require("cosmic.io").barf(path, data)` |
| `cosmo.Slurp(path)` | `require("cosmic.io").slurp(path)` |
| `cosmo.path.join(...)` | `require("cosmic.fs").join(...)` |
| `cosmo.path.isfile(p)` | `require("cosmic.fs").isfile(p)` |
| `cosmo.unix.mkdtemp(t)` | `require("cosmic.fs").mkdtemp(t)` |
| `cosmo.DecodeJson(s)` | `require("cosmic.json").decode(s)` |
| `cosmo.EncodeJson(v)` | `require("cosmic.json").encode(v)` |
| `cosmo.Fetch(url, opts)` | `require("cosmic.fetch").fetch(url, opts)` |

## Writing a Module

1. create `lib/cosmic/mymod.tl` following the standard pattern:

```teal
--- Brief module description.
--- Longer explanation.

local record Widget
  name: string
  size: number
end

--- Create a new widget.
--- @param name string The widget name
--- @param size number The widget size
--- @return Widget
local function new(name: string, size: number): Widget
  return { name = name, size = size }
end

local record MyModule
  new: function(name: string, size: number): Widget
end

local M: MyModule = { new = new }
return M
```

2. create `lib/cosmic/mymod_test.tl` with tests
3. optionally create `lib/cosmic/mymod_example.tl` with examples

## Error Handling

| pattern | when to use |
|---------|-------------|
| `value, string` | most functions (nil + error on failure) |
| `boolean, string` | success/fail operations |
| Result record | complex operations (HTTP fetch) |
| just `value` | infallible operations (encoding, escaping) |

rules:
- never throw from library code
- never silently discard errors
- be consistent within a module
