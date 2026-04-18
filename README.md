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
| [args](lib/cosmic/args.md) |  CLI option definitions for cosmic. |
| [benchmark](lib/cosmic/benchmark.md) |  Go-style benchmark testing. |
| [child](lib/cosmic/child.md) |  Child process management. |
| [codec](lib/cosmic/codec.md) |  Encoding and decoding utilities for various formats. |
| [compress](lib/cosmic/compress.md) |  Compression and decompression utilities. |
| [doc](lib/cosmic/doc.md) |  Extract documentation from Teal files and render as markdown. |
| [doc_render](lib/cosmic/doc_render.md) |  Rendering and .d.tl parsing for the doc module. |
| [doc_types](lib/cosmic/doc_types.md) |  Shared type definitions for the doc and docs modules. |
| [docindex](lib/cosmic/docindex.md) |  Generate a serialized documentation index from source files. |
| [docs](lib/cosmic/docs.md) |  Access embedded documentation from the cosmic binary. |
| [docs_render](lib/cosmic/docs_render.md) |  Rendering functions for the docs module. |
| [embed](lib/cosmic/embed.md) |  Embed files and directories into a cosmic executable. |
| [env](lib/cosmic/env.md) |  Environment variable utilities. |
| [envd](lib/cosmic/envd.md) |  Load environment variables from an embedded env.d directory. |
| [errno](lib/cosmic/errno.md) |  Error information from system calls. |
| [example](lib/cosmic/example.md) |  Go-style executable example testing. |
| [fetch](lib/cosmic/fetch.md) |  Structured HTTP fetch with optional retry. |
| [format](lib/cosmic/format.md) |  Code formatter for Teal and Lua files. |
| [format_rules](lib/cosmic/format_rules.md) |  Formatting rules and classification functions for the code formatter. |
| [fs](lib/cosmic/fs.md) |  Unified filesystem module. |
| [fs_ops](lib/cosmic/fs_ops.md) |  Filesystem file operations, permissions, timestamps, and temp files. |
| [fs_path](lib/cosmic/fs_path.md) |  Path manipulation functions for the filesystem module. |
| [fs_types](lib/cosmic/fs_types.md) |  Shared type definitions for the fs module family. |
| [fs_walk](lib/cosmic/fs_walk.md) |  Directory walking and file collection utilities. |
| [fuzzy](lib/cosmic/fuzzy.md) |  Fuzzy string matching utilities. |
| [gendoc](lib/cosmic/gendoc.md) |  |
| [getopt](lib/cosmic/getopt.md) |  Command-line option parsing utilities. |
| [hash](lib/cosmic/hash.md) |  Hash utilities. |
| [help](lib/cosmic/help.md) |  Help text generation for cosmic CLI. |
| [html](lib/cosmic/html.md) |  HTML utilities. |
| [init](lib/cosmic/init.md) |  Cosmopolitan Lua utilities. |
| [instrument](lib/cosmic/instrument.md) |  CLI instrumentation for timing and resource usage. |
| [io](lib/cosmic/io.md) |  File descriptor I/O operations. |
| [ip](lib/cosmic/ip.md) |  IP address parsing, formatting, and classification utilities. |
| [json](lib/cosmic/json.md) |  JSON encoding and decoding utilities. |
| [landlock](lib/cosmic/landlock.md) |  Linux landlock filesystem sandbox. |
| [main_handlers](lib/cosmic/main_handlers.md) |  Command handler functions for the cosmic CLI. |
| [make](lib/cosmic/make.md) |  Generate Makefiles for Teal projects. |
| [net](lib/cosmic/net.md) |  Networking and socket utilities. |
| [net_socket](lib/cosmic/net_socket.md) |  Socket implementation for the networking module. |
| [pledge](lib/cosmic/pledge.md) |  Restrict the system calls available to the current process. |
| [poll](lib/cosmic/poll.md) |  Typed interface for polling file descriptors. |
| [proc](lib/cosmic/proc.md) |  Current process management. |
| [init](lib/cosmic/quicksand/init.md) |  Network + filesystem process isolation primitives. |
| [netns](lib/cosmic/quicksand/netns.md) |  Linux network-namespace primitives. |
| [proc](lib/cosmic/quicksand/proc.md) |  Process-setup primitives for jail assembly. |
| [proxy](lib/cosmic/quicksand/proxy.md) |  Allowlist HTTP CONNECT + plain-HTTP proxy for sandboxed egress. |
| [rand](lib/cosmic/rand.md) |  Random number generation. |
| [re](lib/cosmic/re.md) |  Regular expression matching using POSIX extended regex syntax. |
| [require](lib/cosmic/require.md) |  Enhanced require with helpful error messages. |
| [shm](lib/cosmic/shm.md) |  Shared memory for inter-process communication. |
| [signal](lib/cosmic/signal.md) |  Signal handling utilities. |
| [sqlite](lib/cosmic/sqlite.md) |  Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns. |
| [sse](lib/cosmic/sse.md) |  Server-Sent Events parser for streaming HTTP responses. |
| [string](lib/cosmic/string.md) |  String utilities. |
| [style](lib/cosmic/style.md) |  Style-check module for cosmic --check-style. |
| [sys](lib/cosmic/sys.md) |  System information utilities. |
| [syslog](lib/cosmic/syslog.md) |  System logging. |
| [teal](lib/cosmic/teal.md) |  Teal compilation and type-checking. |
| [testrun](lib/cosmic/testrun.md) |  Test runner for cosmic executables. |
| [time](lib/cosmic/time.md) |  Time and clock utilities. |
| [tty](lib/cosmic/tty.md) |  Terminal (TTY) utilities. |
| [unveil](lib/cosmic/unveil.md) |  Restrict filesystem visibility to an allowlisted set of paths. |
| [url](lib/cosmic/url.md) |  URL encoding, decoding, parsing, and escaping utilities. |
| [user](lib/cosmic/user.md) |  User and group identity operations. |
| [uuid](lib/cosmic/uuid.md) |  UUID generation utilities. |
| [welcome](lib/cosmic/welcome.md) |  |
| [zip](lib/cosmic/zip.md) |  ZIP archive reading and writing utilities. |

---

Documentation is generated from Teal source files using the `cosmic.doc` module.

To regenerate locally:
```bash
make docs
```

*This branch is automatically updated by GitHub Actions. Do not edit manually.*
