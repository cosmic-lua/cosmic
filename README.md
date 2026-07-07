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
| [assert](lib/cosmic/assert.md) |  Assertion helpers for tests with auto-formatted failure messages. |
| [benchmark](lib/cosmic/benchmark.md) |  Go-style benchmark testing. |
| [child](lib/cosmic/child.md) |  Child process management. |
| [child_io](lib/cosmic/child_io.md) |  Low-level child-process I/O primitives. |
| [args](lib/cosmic/cli/args.md) |  CLI option definitions for cosmic. |
| [help](lib/cosmic/cli/help.md) |  Help text generation for cosmic CLI. |
| [instrument](lib/cosmic/cli/instrument.md) |  CLI instrumentation for timing and resource usage. |
| [main_handlers](lib/cosmic/cli/main_handlers.md) |  Command handler functions for the cosmic CLI. |
| [run](lib/cosmic/cli/run.md) |  Script execution helpers for the cosmic CLI. |
| [script_cache](lib/cosmic/cli/script_cache.md) |  Caches compiled Lua output for .tl scripts run directly (`cosmic |
| [style](lib/cosmic/cli/style.md) |  Style-check module for cosmic --check-style. |
| [welcome](lib/cosmic/cli/welcome.md) |  |
| [codec](lib/cosmic/codec.md) |  Encoding and decoding utilities for various formats. |
| [compress](lib/cosmic/compress.md) |  Compression and decompression utilities. |
| [doc](lib/cosmic/doc.md) |  Extract documentation from Teal files and render as markdown. |
| [doc_render](lib/cosmic/doc_render.md) |  Rendering and .d.tl parsing for the doc module. |
| [doc_types](lib/cosmic/doc_types.md) |  Shared type definitions for the doc and docs modules. |
| [docindex](lib/cosmic/docindex.md) |  Generate a serialized documentation index from source files. |
| [docs](lib/cosmic/docs.md) |  Access embedded documentation — a `go doc`-style CLI over the binary. |
| [docs_lookup](lib/cosmic/docs_lookup.md) |  Symbol lookup and suggestion helpers for the docs module. |
| [docs_render](lib/cosmic/docs_render.md) |  Rendering functions for the docs module. |
| [embed](lib/cosmic/embed.md) |  Embed files and directories into a cosmic executable. |
| [env](lib/cosmic/env.md) |  Environment variable utilities. |
| [envd](lib/cosmic/envd.md) |  Load environment variables from an embedded env.d directory. |
| [errno](lib/cosmic/errno.md) |  Error information from system calls. |
| [example](lib/cosmic/example.md) |  Go-style executable example testing. |
| [fd](lib/cosmic/fd.md) |  File descriptor I/O operations. |
| [fetch](lib/cosmic/fetch.md) |  Structured HTTP fetch with retry, streaming, and honest error channels. |
| [fetch_headers](lib/cosmic/fetch_headers.md) |  Response-header normalization for the cosmic.fetch module. |
| [format](lib/cosmic/format.md) |  Code formatter for Teal and Lua files. |
| [format_rules](lib/cosmic/format_rules.md) |  Formatting rules and classification functions for the code formatter. |
| [file](lib/cosmic/fs/file.md) |  Whole-file content operations: read, write, truncate, write_atomic. |
| [init](lib/cosmic/fs/init.md) |  Unified filesystem module. |
| [ops](lib/cosmic/fs/ops.md) |  Filesystem file operations, permissions, timestamps, and temp files. |
| [path](lib/cosmic/fs/path.md) |  Path manipulation functions for the filesystem module. |
| [types](lib/cosmic/fs/types.md) |  Shared type definitions for the fs module family, plus the runtime |
| [walk](lib/cosmic/fs/walk.md) |  Directory walking and file collection utilities. |
| [fuzzy](lib/cosmic/fuzzy.md) |  Fuzzy string matching utilities. |
| [gendoc](lib/cosmic/gendoc.md) |  |
| [getopt](lib/cosmic/getopt.md) |  Command-line option parsing utilities. |
| [hash](lib/cosmic/hash.md) |  Hash utilities. |
| [html](lib/cosmic/html.md) |  HTML utilities. |
| [init](lib/cosmic/init.md) |  cosmic: a batteries-included Lua/Teal distribution built on |
| [ip](lib/cosmic/ip.md) |  IP address parsing, formatting, and classification utilities. |
| [json](lib/cosmic/json.md) |  JSON encoding and decoding utilities. |
| [landlock](lib/cosmic/landlock.md) |  Linux landlock filesystem sandbox. |
| [make](lib/cosmic/make.md) |  Generate Makefiles for Teal projects. |
| [net](lib/cosmic/net.md) |  Networking and socket utilities. |
| [net_socket](lib/cosmic/net_socket.md) |  Socket implementation for the networking module. |
| [pledge](lib/cosmic/pledge.md) |  Restrict the system calls available to the current process. |
| [poll](lib/cosmic/poll.md) |  Typed interface for polling file descriptors. |
| [proc](lib/cosmic/proc.md) |  Current process management. |
| [public](lib/cosmic/public.md) |  The PUBLIC module manifest: the single source of truth for which |
| [env](lib/cosmic/quicksand/box/env.md) |  Pure env-policy helpers for cosmic.quicksand.Box. |
| [init](lib/cosmic/quicksand/box/init.md) |  Declarative box builder. |
| [merge](lib/cosmic/quicksand/box/merge.md) |  Pure table-merge helpers for cosmic.quicksand.Box. |
| [run](lib/cosmic/quicksand/box/run.md) |  Fork / unshare / exec orchestration for cosmic.quicksand.Box:run. |
| [caps](lib/cosmic/quicksand/caps.md) |  Linux capability bounding-set control for box assembly. |
| [init](lib/cosmic/quicksand/init.md) |  Network + filesystem process isolation primitives. |
| [netns](lib/cosmic/quicksand/netns.md) |  Linux network-namespace primitives. |
| [proc](lib/cosmic/quicksand/proc.md) |  Process-setup primitives for box assembly. |
| [proxy](lib/cosmic/quicksand/proxy.md) |  Allowlist HTTP CONNECT + plain-HTTP proxy for sandboxed egress. |
| [dial](lib/cosmic/quicksand/proxy/dial.md) |  Upstream dialing for the cosmic.quicksand.proxy egress proxy: |
| [http](lib/cosmic/quicksand/proxy/http.md) |  HTTP/1.1 wire helpers for the cosmic.quicksand.proxy egress proxy: |
| [rules](lib/cosmic/quicksand/proxy/rules.md) |  Allowlist rule parsing, validation, and matching for the |
| [serve](lib/cosmic/quicksand/proxy/serve.md) |  Listener, per-connection handler, and logging for the |
| [types](lib/cosmic/quicksand/types.md) |  Shared record and enum types for the cosmic.quicksand family. |
| [rand](lib/cosmic/rand.md) |  Random number generation. |
| [re](lib/cosmic/re.md) |  Regular expression matching using POSIX extended regex syntax. |
| [require](lib/cosmic/require.md) |  Enhanced require with helpful error messages. |
| [sandbox](lib/cosmic/sandbox.md) |  One-call, fail-closed sandbox facade over unveil, landlock, and |
| [shm](lib/cosmic/shm.md) |  Shared memory for inter-process communication. |
| [signal](lib/cosmic/signal.md) |  Signal handling utilities. |
| [sqlite](lib/cosmic/sqlite.md) |  Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns. |
| [sqlite_bind](lib/cosmic/sqlite_bind.md) |  Internal helper for cosmic.sqlite: the BLOB value marker and the shared |
| [sqlite_params](lib/cosmic/sqlite_params.md) |  Internal helper for cosmic.sqlite: the list/named parameter convenience |
| [sqlite_row_iter](lib/cosmic/sqlite_row_iter.md) |  Internal helper for cosmic.sqlite: the row iterator for db:query's hot |
| [sqlite_stmt_cache](lib/cosmic/sqlite_stmt_cache.md) |  Internal helper for cosmic.sqlite: caches prepared statements by SQL |
| [sse](lib/cosmic/sse.md) |  Server-Sent Events parser for streaming HTTP responses. |
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

## perf Package

| Module | Description |
|--------|-------------|
| [child_bench](lib/perf/bench/child_bench.md) |  Subprocess execution scenarios: raw fork/exec/wait overhead via |
| [embed_bench](lib/perf/bench/embed_bench.md) |  Embed/extract scenarios: exercises cosmic.embed's directory walk |
| [embed_startup_bench](lib/perf/bench/embed_startup_bench.md) |  Startup of an embed.run()-produced executable. |
| [fs_bench](lib/perf/bench/fs_bench.md) |  Filesystem scenarios: directory walking, whole-file I/O, tree churn. |
| [fuzzy_bench](lib/perf/bench/fuzzy_bench.md) |  Fuzzy-matching scenarios: cosmic.fuzzy.find_similar over a namespace. |
| [http_bench](lib/perf/bench/http_bench.md) |  HTTP client scenarios against a loopback server. |
| [json_bench](lib/perf/bench/json_bench.md) |  JSON scenarios: decode/encode of small and large payloads. |
| [micro_bench](lib/perf/bench/micro_bench.md) |  CPU-bound scenarios: hashing, encoding, compression, string handling. |
| [sqlite_bench](lib/perf/bench/sqlite_bench.md) |  SQLite scenarios: transactional writes, point queries, aggregate scans. |
| [startup_bench](lib/perf/bench/startup_bench.md) |  End-to-end binary scenarios: process startup and Teal compilation. |
| [stream_bench](lib/perf/bench/stream_bench.md) |  Streaming HTTP line-iteration against a loopback server. |
| [time_bench](lib/perf/bench/time_bench.md) |  Date/time formatting scenarios. |
| [compare](lib/perf/compare.md) |  Baseline-vs-current comparison gate for perf results. |
| [harness](lib/perf/harness.md) |  Scenario benchmark harness: wall-clock timing with functional checks. |
| [perf_types](lib/perf/perf_types.md) |  Shared type definitions for the perf harness (lib/perf). |
| [run](lib/perf/run.md) |  |
| [stats](lib/perf/stats.md) |  Basic statistics over benchmark samples. |

---

Documentation is generated from Teal source files using the `cosmic.doc` module.

To regenerate locally:
```bash
make docs
```

*This branch is automatically updated by GitHub Actions. Do not edit manually.*
