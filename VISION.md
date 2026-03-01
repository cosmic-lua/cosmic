# Vision

## North Star

cosmic is a portable, batteries-included systems programming environment. one binary, every platform, no installation. write a script, ship an executable.

the goal is to cover the full surface of [Cosmopolitan Libc](https://github.com/jart/cosmopolitan) with a clean, typed standard library — then make it the easiest way to build and distribute software that runs everywhere.

## End State

a programmer downloads a single file. they write typed code with a real standard library — filesystem, networking, crypto, databases, compression, IPC — and produce a fat binary that runs on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD without modification. no toolchain to install. no containers to configure. no cross-compilation matrix.

this is harness engineering: make the right thing the default thing. the stdlib is the harness. it encodes good defaults — error handling, type safety, security sandboxing, portable abstractions — so that every program written against it inherits those properties automatically.

## Design Principles

**one binary.** cosmic is a single executable. it contains the runtime, compiler, type checker, standard library, documentation, and build tools. everything ships together. nothing to install, nothing to link.

**typed by default.** Teal gives static types over Lua. every `cosmic.*` module has full type annotations. type errors are caught before runtime. the type system is the first line of defense.

**errors are values.** functions return `value, error`. no exceptions from library code. errors propagate explicitly. the caller always decides what to do. inspired by Go.

**batteries included.** the stdlib should cover what Go, Python, and Rust cover in their standard libraries: filesystem, networking, HTTP, JSON, SQL, crypto, compression, process management, signal handling, terminal I/O, regex, UUID, time. if cosmopolitan exposes it, cosmic should wrap it.

**consistent surface.** every module follows the same patterns: `snake_case` names, doc comments, error returns, record types. learning one module teaches you all of them. inspired by Rust's std and Go's stdlib.

**secure by default.** pledge and unveil are first-class. programs can drop capabilities. the build system itself is sandboxed. security is a feature of the platform, not an afterthought.

**portable without abstraction tax.** cosmopolitan handles the platform differences in C. cosmic exposes a single API. no `#ifdef`, no platform switches, no conditional imports. code works the same on every OS.

## Inspirations

| source | what we take |
|--------|-------------|
| **Go** | batteries-included stdlib, error-as-values, single-binary output, built-in formatting and testing |
| **Python** | "comes with batteries", discoverability, REPL, scripting ergonomics |
| **Rust** | type safety, consistent API design, documentation culture, `Result`-style error handling |
| **Cosmopolitan** | actually portable native binaries, pledge/unveil, zip executable format |
| **Lua/Teal** | small core, embeddable, fast, gradual typing |

## Coverage Targets

### Currently Wrapped

filesystem, networking (TCP/UDP/Unix), HTTP client, JSON, SQLite, compression, hashing (SHA-256, Argon2), regex, signals, child processes, shared memory, polling, terminal I/O, syslog, environment, sandbox (pledge/unveil), IP addresses, URLs, UUIDs, SSE, ZIP archives.

### Gaps to Fill

these are capabilities cosmopolitan exposes that cosmic should wrap:

| area | cosmopolitan | cosmic module |
|------|-------------|---------------|
| TLS/SSL | built-in mbedtls | `cosmic.tls` |
| HTTP server | redbean heritage | `cosmic.http` |
| DNS | `ResolveDns`, `GetAddrInfo` | `cosmic.dns` |
| mmap | `unix.mmap` | `cosmic.mmap` |
| file locking | `unix.flock`, `fcntl` | `cosmic.fs` (extend) |
| inotify/kqueue | file watching | `cosmic.watch` |
| pty | pseudo-terminals | `cosmic.pty` |
| base64/base32 | `EncodeBase64`, `DecodeBase64` | `cosmic.codec` (extend) |
| datetimes | `FormatHttpDateTime`, parsing | `cosmic.time` (extend) |
| UNIX domain sockets | `unix.socket` AF_UNIX | `cosmic.net` (extend) |
| `posix_spawn` | `unix.posix_spawn` | `cosmic.child` (extend) |
| resource limits | `setrlimit`, `getrlimit` | `cosmic.proc` (extend) |
| semaphores | futex-based | `cosmic.sync` |
| pipes | `unix.pipe` | `cosmic.io` (extend) |

### Aspirational

these require upstream cosmopolitan work or significant new code:

- `cosmic.async` — event loop with coroutine-based concurrency
- `cosmic.log` — structured logging (beyond syslog)
- `cosmic.cli` — higher-level CLI framework (subcommands, help generation)
- `cosmic.template` — text templating
- `cosmic.csv` — CSV parsing
- `cosmic.toml` — TOML parsing
- `cosmic.ini` — INI parsing
- `cosmic.tar` — tar archives
- `cosmic.test` — richer assertion library

## Success Criteria

1. **coverage**: every `cosmo.*` binding has a typed `cosmic.*` wrapper with docs, tests, and examples.
2. **portability**: every module works on all six supported operating systems.
3. **discoverability**: `cosmic --docs` can answer "how do I do X?" for any common systems programming task.
4. **single-binary delivery**: any cosmic program can be packaged as one file via `cosmic --embed`.
5. **zero-install adoption**: download → run → ship. nothing else required.
