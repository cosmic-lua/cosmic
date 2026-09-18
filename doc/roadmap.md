# roadmap

what comes after the current state in [design.md](design.md), and
the questions still open. this doc is read alongside design.md, not
instead of it: design.md says what cosmic is, this says what is
next and what is undecided.

## status

**milestone 1, hello from the database, is done.** `bin/zig build
cores boot` from a fresh clone builds three cores and one database,
`cosmic hello.tl` runs on the host, and a second clone at a
different path produces byte-identical binaries and database. the
Mach-O signature is accepted by `codesign --verify --strict` and
independently re-verified page by page. three review rounds found
and closed: raw SQLite and the database VFS reachable from any
script; a project able to shadow `cosmic.*`; the declaration
generator accepting an incomplete annotation; undefined behavior and
an unbounded parse in the executable locator; missing `O_CLOEXEC`;
two independent copies of the zig version pin. four of tl's carried
narrowing patches landed already, ahead of schedule, because honest
returns need them to narrow at an index.

**milestone 2, self-check, is next.**

## milestone 2: self-check

`cosmic check` and `cosmic test` gate cosmic's own tree,
incrementally, under the foreclosed-cast checker, with records in a
database of their own. it adds:

- **the stale-tool re-exec.** milestone 1 detects a stale tool and
  refuses; it has no child process yet to re-exec into. this is
  where that lands.
- **the provenance gate.** asserts that no bytes from outside the
  tree and the pinned zig reach an output, checked by building on
  two hosts and comparing hashes.
- **`O_CLOEXEC` on the remaining `fopen` paths** in boot and the
  patch applier; the syscall table's own `open` already sets it.
- **a fuzzer over the executable locator**, now that it parses
  untrusted bytes at every startup.
- **the visibility lint**: no import of a private module from
  outside its tree; no two names in a directory differing only in
  case.
- **project type-checking against `cosmic.*`**: a project can run
  `cosmic check` today only because `hello.tl` imports nothing; a
  real project needs the binary's declarations on disk or in a form
  the checker can read.
- **`o/records.db`**, test verdicts and coverage keyed by source
  hash and by what a test was observed to read, never shipped.
- **test discovery at compile time**, spawning per test for
  isolation, a temp directory, and a deadline, results returned over
  a pipe rather than written by the child.
- **the doc extractor and the example runner**, per meta.md.
- the remaining tl narrowing patches record-field narrowing and
  container covariance need, so the cast-foreclosure rule holds
  against real code rather than only against `hello.tl`.

## milestone 3 and the release bar

the core tier, then the second, each module earning its place. a
release ships when three things hold: cosmic builds and tests the
work board, gitboard, from its own tree; the agent evaluation suite
scores at or above its recorded baseline; the release job produces
all three targets and the repro lane proves them byte-identical.

## open questions

- **host language and toolchain.** Rust as the host was weighed and
  deferred before milestone 1; zig as the language was set aside.
  revisit now that a real C core and build.zig exist to compare
  against, not a sketch.
- **FTS5.** measured at 222 KB per core image, three images per
  binary. milestone 1 produced the per-component size line the
  design's size report wanted; the decision itself is still open,
  and belongs to whoever needs full-text search first.
- **an address-sanitized lane** on a clang outside the pinned
  toolchain. deferred until the C core is large enough to want it;
  milestone 1's core is a few files and hasn't earned the second
  toolchain yet.
