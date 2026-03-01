# Direction

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

### Binding Surface

cosmopolitan exposes ~48 top-level `cosmo.*` functions, ~133 `cosmo.unix.*` functions, and ~73 record methods across `unix.Stat`, `unix.Dir`, `unix.Memory`, `unix.Rusage`, etc. additionally there are dedicated modules: `cosmo.path` (8 functions), `cosmo.re` (6), `cosmo.zip` (11), `cosmo.lsqlite3` (28), `cosmo.getopt` (4), `cosmo.argon2` (2).

current `cosmic.*` modules wrap the most-used subset. the gap is tracked below.

### Gaps to Fill

each row has a status: **—** (not started), **partial**, or **done**.

| area | cosmopolitan | cosmic module | status |
|------|-------------|---------------|--------|
| TLS/SSL | built-in mbedtls | `cosmic.tls` | — |
| HTTP server | redbean heritage | `cosmic.http` | — |
| DNS | `ResolveIp` | `cosmic.dns` | — |
| mmap | `unix.mmap` | `cosmic.mmap` | — |
| file locking | `unix.flock`, `fcntl` | `cosmic.fs` (extend) | — |
| file watching | inotify/kqueue | `cosmic.watch` | — |
| pty | pseudo-terminals | `cosmic.pty` | — |
| base64/base32 | `EncodeBase64`, `DecodeBase64` | `cosmic.codec` (extend) | — |
| HTTP datetimes | `FormatHttpDateTime`, `ParseHttpDateTime` | `cosmic.time` (extend) | — |
| `posix_spawn` | `unix.posix_spawn` | `cosmic.child` (extend) | — |
| resource limits | `setrlimit`, `getrlimit` | `cosmic.proc` (extend) | — |
| semaphores | futex-based | `cosmic.sync` | — |

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

## Scoreboard

these metrics are checkable against the repo. update them as work lands.

| metric | current | target | how to check |
|--------|---------|--------|-------------|
| `cosmic.*` library modules | 34 | — | `ls lib/cosmic/*.tl \| grep -v _test \| grep -v _example \| grep -v _types \| wc -l` (minus internal modules) |
| modules with tests | 49/60 | 60/60 | `for f in lib/cosmic/*.tl; do test -f "${f%.tl}_test.tl" && echo y; done \| wc -l` |
| modules with examples | 9/60 | 34/60 | `ls lib/cosmic/*_example.tl \| wc -l` |
| `cosmo.*` functions wrapped | ~30/48 | 48/48 | audit `cosmo.d.tl` functions against `cosmic.*` exports |
| `cosmo.unix.*` functions wrapped | ~40/133 | 133/133 | audit `unix.d.tl` functions against `cosmic.*` exports |
| gaps-to-fill rows at "done" | 0/12 | 12/12 | count status column above |
| CI passes on all platforms | linux+macos | 6 OS | check CI matrix in `pr.yml` |
| doc coverage | all modules | all functions | `cosmic --docs` returns results for every exported function |
| type check clean | yes | yes | `bin/make teal` exits 0 with no warnings |
| format clean | yes | yes | `bin/make format` exits 0 |

## Success Criteria

the project is done when:

1. **full binding coverage**: every function in `cosmo.d.tl` and `cosmo/unix.d.tl` has a typed `cosmic.*` wrapper. measured by the scoreboard above reaching 48/48 and 133/133.
2. **every module has tests and examples**: scoreboard rows for tests and examples both reach their targets.
3. **all gaps filled**: every row in the gaps-to-fill table reaches "done" status.
4. **six-OS CI**: CI runs tests on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD. currently linux and macos.
5. **doc coverage**: `cosmic --docs <function>` returns documentation for every exported function in every module. no gaps.
6. **zero-install adoption**: a user can `curl` the binary and immediately write, type-check, test, and ship a program. no other tool required. validated by a single-command smoke test in CI.
