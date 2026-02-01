# Generated Documentation

This branch contains auto-generated documentation from the cosmic-lua source code.

## cosmo Package

Core Cosmopolitan Libc bindings and system interfaces.

| Module | Description |
|--------|-------------|
| [argon2](cosmo/argon2.md) | Type declarations for the `argon2` module. |
| [finger](cosmo/finger.md) | Type declarations for the `finger` module. |
| [getopt](cosmo/getopt.md) | Type declarations for the `getopt` module. |
| [goodsocket](cosmo/goodsocket.md) | Type declarations for the `goodsocket` module. |
| [lsqlite3](cosmo/lsqlite3.md) | Type declarations for the `lsqlite3` module. |
| [maxmind](cosmo/maxmind.md) | Type declarations for the `maxmind` module. |
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
| [child](lib/cosmic/child.md) |  Child process management. |
| [codec](lib/cosmic/codec.md) |  Encoding and decoding utilities for various formats. |
| [doc](lib/cosmic/doc.md) |  Extract documentation from Teal files and render as markdown. |
| [docindex](lib/cosmic/docindex.md) |  Generate a serialized documentation index from source files. |
| [docs](lib/cosmic/docs.md) |  Access embedded documentation from the cosmic binary. |
| [embed](lib/cosmic/embed.md) |  Embed files into cosmic executable. |
| [env](lib/cosmic/env.md) |  Environment variable utilities. |
| [example](lib/cosmic/example.md) |  Go-style executable example testing. |
| [fetch](lib/cosmic/fetch.md) |  Structured HTTP fetch with optional retry. |
| [fs](lib/cosmic/fs.md) |  Filesystem operations. |
| [fuzzy](lib/cosmic/fuzzy.md) |  Fuzzy string matching utilities. |
| [gendoc](lib/cosmic/gendoc.md) |  |
| [getopt](lib/cosmic/getopt.md) |  Command-line option parsing utilities. |
| [init](lib/cosmic/init.md) |  Cosmopolitan Lua utilities. |
| [io](lib/cosmic/io.md) |  File descriptor I/O operations. |
| [json](lib/cosmic/json.md) |  JSON encoding and decoding utilities. |
| [net](lib/cosmic/net.md) |  Networking and socket utilities. |
| [path](lib/cosmic/path.md) |  Path manipulation utilities. |
| [proc](lib/cosmic/proc.md) |  Current process management. |
| [re](lib/cosmic/re.md) |  Regular expression matching using POSIX extended regex syntax. |
| [require](lib/cosmic/require.md) |  Enhanced require with helpful error messages. |
| [sandbox](lib/cosmic/sandbox.md) |  Security sandboxing utilities. |
| [shm](lib/cosmic/shm.md) |  Shared memory for inter-process communication. |
| [signal](lib/cosmic/signal.md) |  Signal handling utilities. |
| [sqlite](lib/cosmic/sqlite.md) |  Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns. |
| [sys](lib/cosmic/sys.md) |  System information utilities. |
| [teal](lib/cosmic/teal.md) |  Teal compilation and type-checking. |
| [time](lib/cosmic/time.md) |  Time and clock utilities. |
| [tty](lib/cosmic/tty.md) |  Terminal (TTY) utilities. |
| [url](lib/cosmic/url.md) |  URL encoding, decoding, and query string parsing utilities. |
| [user](lib/cosmic/user.md) |  User and group identity operations. |
| [walk](lib/cosmic/walk.md) |  Directory tree walking utilities. |
| [welcome](lib/cosmic/welcome.md) |  |
| [zip](lib/cosmic/zip.md) |  ZIP archive reading and writing utilities. |

---

Documentation is generated from Teal source files using the `cosmic.doc` module.

To regenerate locally:
```bash
make docs
```

*This branch is automatically updated by GitHub Actions. Do not edit manually.*
