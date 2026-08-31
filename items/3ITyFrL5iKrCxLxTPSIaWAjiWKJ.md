## Change

Extract the five duplicated bench helpers into two shared modules and add `_perf`
to the dupes gate's scope.

`_build/dupes.tl`'s `TREES` comment names this as the other standing exclusion:
"`_perf` (five duplicated bench helpers) ... join once their standing duplicates
are exported and required". Running the gate's scanner with `_perf` added reports
exactly five groups over 16 sites:

| helper | sites | lines each |
|---|---|---|
| `read_request(conn: net.Socket): boolean` | `download_bench:44`, `http_bench:27`, `stream_bench:67` | 11 |
| `send_all(conn: net.Socket, data: string): boolean` | `download_bench:60`, `stream_bench:51` | 12 |
| `cleanup()` (server flavour) | `download_bench:154`, `http_bench:177`, `stream_bench:156` | 11 |
| `find_bin(): string \| nil` | `embed_bench:36`, `embed_startup_bench:37`, `startup_bench:39` | 18 |
| `cleanup()` (artifact flavour) | `embed_bench:195`, `embed_startup_bench:161`, `fs_bench:203`, `startup_bench:157`, `tar_bench:145` | 6 |

All paths are under `_perf/bench/`. The two `cleanup()` sets are **distinct
bodies** — the scanner groups by normalized body and reported them as two separate
groups, so they become two functions, not one.

58 lines of body across 16 sites; keeping one copy of each removes roughly 116
lines.

### Files

Two new modules, split along the line the two groups already draw — a socket
server the HTTP-shaped benches stand up, and a built binary the artifact-shaped
benches locate and clean up after:

- `_perf/bench/server.tl` — `read_request`, `send_all`, and the server-flavour
  `cleanup`.
- `_perf/bench/binary.tl` — `find_bin` and the artifact-flavour `cleanup`.

Neither is a `*_bench.tl`, so the runner does not enumerate them as bench modules;
`_perf` is already internal by position, so no underscore prefix is needed.

- `_perf/bench/{download,http,stream}_bench.tl` — delete the three local copies
  each carries; require `_perf.bench.server`.
- `_perf/bench/{embed,embed_startup,fs,startup,tar}_bench.tl` — same against
  `_perf.bench.binary`.
- `_build/dupes.tl` — add `"_perf"` to `TREES`.
- `_build/dupes_test.tl` — add `_perf` to the `--- reads:` line, which mirrors
  `TREES`.

### The benches must still measure the same thing

`_perf` scenarios carry per-scenario functional checks, and the `optimize` skill's
rule is that a scenario is never weakened to make numbers move. Extraction is a
refactor, so the gate is that the scenarios still pass their own checks and that
the comparison against a pre-change baseline shows no shift outside noise —
`_perf/gate.tl compare` with a `selfcheck` pair for the noise floor, per the skill.
Run it; a helper that changed a socket's buffering would show up there and nowhere
else.

### Landing order

The sibling item adding `cosmic` to the gate edits the same two lines in
`_build/dupes.tl` and `_build/dupes_test.tl`. Whichever lands second rebases.

## Non-goals

- No change to what any scenario measures, to its functional checks, or to the
  harness.
- No new gate. This widens an existing one's scope.
