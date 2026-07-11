# Generated Documentation

This branch contains auto-generated documentation from the cosmic-lua source code.

## cosmo Package

Core Cosmopolitan Libc bindings and system interfaces.

| Module | Description |
|--------|-------------|
| [argon2](cosmo/argon2.md) | Type declarations for the `argon2` module. |
| [getopt](cosmo/getopt.md) | Type declarations for the `getopt` module. |
| [lsqlite3](cosmo/lsqlite3.md) | Type declarations for the `lsqlite3` module. |
| [path](cosmo/path.md) | Type declarations for the `path` module. |
| [re](cosmo/re.md) | Type declarations for the `re` module. |
| [repl](cosmo/repl.md) | Type declarations for the `repl` module. |
| [unix](cosmo/unix.md) | Type declarations for the `unix` module. |
| [zip](cosmo/zip.md) | Type declarations for the `zip` module. |

## cosmic Package

High-level utilities and tools built on top of cosmo.

| Module | Description |
|--------|-------------|
| [benchmark](lib/cosmic/benchmark.md) |  Go-style benchmark testing. |
| [check](lib/cosmic/check.md) |  Assertion helpers for tests with auto-formatted failure messages. |
| [init](lib/cosmic/child/init.md) |  Child process management. |
| [codec](lib/cosmic/codec.md) |  Encoding and decoding utilities for various formats. |
| [compress](lib/cosmic/compress.md) |  Compression and decompression utilities. |
| [init](lib/cosmic/coverage/init.md) |  Line coverage collection for cosmic programs. |
| [init](lib/cosmic/doc/init.md) |  Extract documentation from Teal files and render as markdown. |
| [embed](lib/cosmic/embed.md) |  Embed files and directories into a cosmic executable. |
| [env](lib/cosmic/env.md) |  Environment variable utilities. |
| [envd](lib/cosmic/envd.md) |  Load environment variables from an embedded env.d directory. |
| [errno](lib/cosmic/errno.md) |  Error information from system calls. |
| [example](lib/cosmic/example.md) |  Go-style executable example testing. |
| [fd](lib/cosmic/fd.md) |  File descriptor I/O operations. |
| [init](lib/cosmic/fetch/init.md) |  Structured HTTP fetch with retry, streaming, and honest error channels. |
| [init](lib/cosmic/format/init.md) |  Code formatter for Teal and Lua files. |
| [init](lib/cosmic/fs/init.md) |  Unified filesystem module. |
| [fuzzy](lib/cosmic/fuzzy.md) |  Fuzzy string matching utilities. |
| [getopt](lib/cosmic/getopt.md) |  Command-line option parsing utilities. |
| [hash](lib/cosmic/hash.md) |  Hash utilities. |
| [html](lib/cosmic/html.md) |  HTML utilities. |
| [ip](lib/cosmic/ip.md) |  IP address parsing, formatting, and classification utilities. |
| [json](lib/cosmic/json.md) |  JSON encoding and decoding utilities. |
| [landlock](lib/cosmic/landlock.md) |  Linux landlock filesystem sandbox. |
| [init](lib/cosmic/net/init.md) |  Networking and socket utilities. |
| [pledge](lib/cosmic/pledge.md) |  Restrict the system calls available to the current process. |
| [poll](lib/cosmic/poll.md) |  Typed interface for polling file descriptors. |
| [proc](lib/cosmic/proc.md) |  Current process management. |
| [init](lib/cosmic/quicksand/init.md) |  Network + filesystem process isolation primitives. |
| [rand](lib/cosmic/rand.md) |  Random number generation. |
| [re](lib/cosmic/re.md) |  Regular expression matching using POSIX extended regex syntax. |
| [sandbox](lib/cosmic/sandbox.md) |  One-call, fail-closed sandbox facade over unveil, landlock, and |
| [shm](lib/cosmic/shm.md) |  Shared memory for inter-process communication. |
| [signal](lib/cosmic/signal.md) |  Signal handling utilities. |
| [init](lib/cosmic/sqlite/init.md) |  Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns. |
| [sse](lib/cosmic/sse.md) |  Server-Sent Events parser for streaming HTTP responses. |
| [stream](lib/cosmic/stream.md) |  The stream contract: the byte-stream interfaces every producer and |
| [string](lib/cosmic/string.md) |  String utilities. |
| [sys](lib/cosmic/sys.md) |  System information utilities. |
| [syslog](lib/cosmic/syslog.md) |  System logging. |
| [teal](lib/cosmic/teal.md) |  Teal compilation and type-checking. |
| [testrun](lib/cosmic/testrun.md) |  Test runner for cosmic executables. |
| [time](lib/cosmic/time.md) |  Time and clock utilities. |
| [tty](lib/cosmic/tty.md) |  Terminal (TTY) utilities. |
| [unveil](lib/cosmic/unveil.md) |  Restrict filesystem visibility to an allowlisted set of paths. |
| [url](lib/cosmic/url.md) |  URL encoding, decoding, parsing, formatting, and escaping utilities. |
| [user](lib/cosmic/user.md) |  User and group identity operations. |
| [uuid](lib/cosmic/uuid.md) |  UUID generation utilities. |
| [zip](lib/cosmic/zip.md) |  ZIP archive reading and writing utilities. |

---

Documentation is generated from Teal source files using the `cosmic.doc` module.

To regenerate locally:
```bash
make docs
```

*This branch is automatically updated by GitHub Actions. Do not edit manually.*
