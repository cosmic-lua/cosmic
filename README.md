# Generated Documentation

This branch contains auto-generated documentation from the cosmic-lua source code.

## cosmic Package

High-level utilities and tools built on top of cosmo.

| Module | Description |
|--------|-------------|
| [ansi](cosmic/ansi.md) |  ANSI terminal styling. |
| [benchmark](cosmic/benchmark.md) |  Go-style benchmark testing. |
| [check](cosmic/check.md) |  Assertion helpers for tests with auto-formatted failure messages. |
| [init](cosmic/child/init.md) |  Child process management. |
| [codec](cosmic/codec.md) |  Encoding and decoding utilities for various formats. |
| [compress](cosmic/compress.md) |  Compression and decompression utilities. |
| [init](cosmic/coverage/init.md) |  Line coverage collection for cosmic programs. |
| [init](cosmic/doc/init.md) |  Extract documentation from Teal files and render as markdown. |
| [init](cosmic/embed/init.md) |  Embed files and directories into a cosmic executable. |
| [env](cosmic/env.md) |  Environment variable utilities. |
| [envd](cosmic/envd.md) |  Load environment variables from an embedded env.d directory. |
| [errno](cosmic/errno.md) |  Error information from system calls. |
| [example](cosmic/example.md) |  Go-style executable example testing. |
| [fd](cosmic/fd.md) |  File descriptor I/O operations. |
| [init](cosmic/fetch/init.md) |  Structured HTTP fetch with retry, streaming, and honest error channels. |
| [init](cosmic/flags/init.md) |  Declarative command-line flag parsing. |
| [init](cosmic/format/init.md) |  Code formatter for Teal and Lua files. |
| [init](cosmic/fs/init.md) |  Unified filesystem module. |
| [fuzzy](cosmic/fuzzy.md) |  Fuzzy string matching utilities. |
| [getopt](cosmic/getopt.md) |  Command-line option parsing utilities. |
| [hash](cosmic/hash.md) |  Hash utilities. |
| [html](cosmic/html.md) |  HTML utilities. |
| [init](cosmic/init.md) |  cosmic: a batteries-included Lua/Teal distribution built on |
| [instrument](cosmic/instrument.md) |  Instrumentation for timing and resource usage: wrap an operation in |
| [ip](cosmic/ip.md) |  IP address parsing, formatting, and classification utilities. |
| [json](cosmic/json.md) |  JSON encoding and decoding utilities. |
| [landlock](cosmic/landlock.md) |  Linux landlock filesystem sandbox. |
| [literal](cosmic/literal.md) |  Teal source read as **data**: one `return { … }` of literals, lexed |
| [log](cosmic/log.md) |  Leveled logging. |
| [init](cosmic/net/init.md) |  Networking and socket utilities. |
| [pledge](cosmic/pledge.md) |  Restrict the system calls available to the current process. |
| [poll](cosmic/poll.md) |  Typed interface for polling file descriptors. |
| [init](cosmic/proc/init.md) |  Current process management. |
| [init](cosmic/quicksand/init.md) |  Network + filesystem process isolation primitives. |
| [rand](cosmic/rand.md) |  Random number generation. |
| [re](cosmic/re.md) |  Regular expression matching using POSIX extended regex syntax. |
| [records](cosmic/records.md) |  The records a build writes, and the one grammar they are written in. |
| [sandbox](cosmic/sandbox.md) |  One-call, fail-closed sandbox facade over unveil, landlock, and |
| [searcher](cosmic/searcher.md) |  cosmic-owned runtime .tl package searcher, replacing |
| [shm](cosmic/shm.md) |  Shared memory for inter-process communication. |
| [signal](cosmic/signal.md) |  Signal handling utilities. |
| [init](cosmic/sqlite/init.md) |  Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns. |
| [sse](cosmic/sse.md) |  Server-Sent Events: parse a stream of them, format one for the wire. |
| [stream](cosmic/stream.md) |  The stream contract: the byte-stream interfaces every producer and |
| [string](cosmic/string.md) |  String utilities. |
| [style](cosmic/style.md) |  The PURE style checks: file length and column width. |
| [sys](cosmic/sys.md) |  System information utilities. |
| [syslog](cosmic/syslog.md) |  System logging. |
| [table](cosmic/table.md) |  Table utilities. |
| [tar](cosmic/tar.md) |  |
| [teal](cosmic/teal.md) |  Teal compilation and type-checking. |
| [testrun](cosmic/testrun.md) |  Test runner for cosmic executables. |
| [time](cosmic/time.md) |  Time and clock utilities. |
| [tty](cosmic/tty.md) |  Terminal (TTY) utilities. |
| [unveil](cosmic/unveil.md) |  Restrict filesystem visibility to an allowlisted set of paths. |
| [url](cosmic/url.md) |  URL encoding, decoding, parsing, formatting, and escaping utilities. |
| [user](cosmic/user.md) |  User and group identity operations. |
| [uuid](cosmic/uuid.md) |  UUID generation utilities. |
| [zip](cosmic/zip.md) |  ZIP archive reading and writing. |

---

Documentation is generated from Teal source files using the `cosmic.doc` module.

To regenerate locally:
```bash
make docs
```

*This branch is automatically updated by GitHub Actions. Do not edit manually.*
