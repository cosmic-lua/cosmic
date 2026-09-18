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
database of their own. the order below is the priority, not a bag
of items: tests first, then ast, checking, and formatting, since a
checker and a formatter both work over an AST and now sit in the
same tier as it.

**first: tests, doctests, and coverage.** none of this waits on
process isolation to be useful; isolation is a layer added on top,
not a gate in front:

- **test discovery at compile time**, the same lexer walk over
  source the compiler already does, finding `local function test_*`
  names in a `kind = "test"` module and recording them.
- **the runner**, in-process at first: `pcall` around each test
  call, a fresh temp directory per test from `mkdtemp`, a pass/fail
  verdict. an assertion failure is an ordinary Lua error and needs
  nothing more than this to catch. a hang or a crash still takes
  down the run; those two gaps are named, not hidden, and close once
  child-process spawning exists, by wrapping this same calling code
  in a spawned child, not by rewriting the runner.
- **the doctest extractor**, per meta.md: fenced blocks from a doc
  become one compiled Teal file, one function per example, so the
  compiled file is a test file and needs no runner of its own.
- **Lua and Teal coverage**, `debug.sethook` in line mode through
  the private binding already reserved for it, reading the line
  numbers the bytecode already carries.
- **C coverage** on `core/*.c` only, source-based LLVM
  instrumentation (`-fprofile-instr-generate -fcoverage-mapping`),
  with a vendored `compiler-rt` profile runtime built per target,
  since zig ships the instrumentation but no runtime to act on it,
  the same shape as the ASan finding. `llvm-profdata` and
  `llvm-cov`, pinned to zig's bundled LLVM version and re-verified
  on every zig bump, turn the result into one JSON export.
- **`o/records.db`**, test verdicts and coverage keyed by source
  hash and by what a test was observed to read (every file access
  already goes through the syscall table, so the runner can record
  what a test touched instead of relying on a hand-written
  declaration), never shipped.

**second: ast, checking, formatting.** `cosmic.ast`, structural Teal
parsing, matching, and rewriting, is what both of the following read
and lean on:

- **`cosmic check`**: the foreclosed-cast checker gate over a
  project, which needs the binary's own declarations reachable on
  disk or in a form the checker can read, since a real project
  imports more than `hello.tl` does today.
- **`cosmic format`**: the formatter, renamed to match the module.
- **the visibility lint**, part of what "checking" means: no import
  of a private module from outside its tree, no two names in a
  directory differing only in case.
- **the remaining tl narrowing patches**, record-field narrowing and
  container covariance, so cast-foreclosure holds against real code,
  not only `hello.tl`.

**alongside, not gating either priority above:**

- **child-process spawning**, `cosmic.child` over `posix_spawn`.
  serves two things at once once it lands: the isolation layer the
  test runner names as its own follow-up, and the re-exec the
  stale-tool refusal needs (milestone 1 detects a stale tool and
  refuses; it has no process yet to re-exec into).
- **the provenance gate**: no bytes from outside the tree and the
  pinned zig reach an output, checked by building on two hosts and
  comparing hashes.
- **`O_CLOEXEC` on the remaining `fopen` paths** in boot and the
  patch applier; the syscall table's own `open` already sets it.
- **a fuzzer over the executable locator**, now that it parses
  untrusted bytes at every startup.

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
