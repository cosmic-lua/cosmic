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
| [init](lib/cosmic/init.md) |  Cosmopolitan Lua utilities. |
| [io](lib/cosmic/io.md) |  File descriptor I/O operations. |
| [json](lib/cosmic/json.md) |  JSON encoding and decoding utilities. |
| [net](lib/cosmic/net.md) |  Networking and socket utilities. |
| [path](lib/cosmic/path.md) |  Path manipulation utilities. |
| [require](lib/cosmic/require.md) |  Enhanced require with helpful error messages. |
| [spawn](lib/cosmic/spawn.md) |  Process spawning utilities. |
| [sqlite](lib/cosmic/sqlite.md) |  Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns. |
| [teal](lib/cosmic/teal.md) |  Teal compilation and type-checking. |
| [time](lib/cosmic/time.md) |  Time and clock utilities. |
| [url](lib/cosmic/url.md) |  URL encoding, decoding, and query string parsing utilities. |
| [walk](lib/cosmic/walk.md) |  Directory tree walking utilities. |
| [welcome](lib/cosmic/welcome.md) |  |

---

Documentation is generated from Teal source files using the `cosmic.doc` module.

To regenerate locally:
```bash
make docs
```

*This branch is automatically updated by GitHub Actions. Do not edit manually.*
