# roadmap

what comes after the current state in [design.md](design.md), and
the questions still open. this doc is read alongside design.md, not
instead of it: design.md says what cosmic is, this says what is
next and what is undecided.

## self-check

`cosmic check` and `cosmic test` gate cosmic's own tree,
incrementally, under the foreclosed-cast checker, with records in a
database of their own. tests, the in-process runner, and a real Teal
AST (`build.ast`: parse, walk, structural match, rewrite) have
already landed; what follows leans on `build.ast`, still
build-internal today, and on `o/records.db`, which already holds
test verdicts.

- **the doctest extractor**, per meta.md: fenced blocks from a doc
  become one compiled Teal file, one function per example, so the
  compiled file is a test file and needs no runner of its own.
- **Lua and Teal coverage**, `debug.sethook` in line mode through
  the private binding already reserved for it, reading the line
  numbers the bytecode already carries, recorded into
  `o/records.db` alongside test verdicts.

**deferred, not dropped: C testing and coverage.** no C-level unit
test framework exists yet, and C coverage is researched but not
built: source-based LLVM instrumentation on `core/*.c` only
(`-fprofile-instr-generate -fcoverage-mapping`), a vendored
`compiler-rt` profile runtime per target since zig ships the
instrumentation but no runtime to act on it, `llvm-profdata` and
`llvm-cov` pinned to zig's bundled LLVM version and re-verified on
every bump, `llvm-cov export` as one JSON. both wait until Lua and
Teal testing exists first, deliberately: `core/*.c` is a handful of
files today, and the cost of waiting is small next to the cost of
building two systems that diverge. the requirement once they land:
the same facilities and the same ergonomics as Lua and Teal testing,
not a separate system beside it, one discovery convention, one verb
that runs both, coverage reported the same way for either.

- **`cosmic check`**: the foreclosed-cast checker gate over a
  project, which needs the binary's own declarations reachable on
  disk or in a form the checker can read, since a real project
  imports more than a trivial one-file script does today.
- **`cosmic format`**: the formatter, renamed to match the module.
- **the visibility lint**, part of what "checking" means: no import
  of a private module from outside its tree, no two names in a
  directory differing only in case.
- **the remaining tl narrowing patches**, record-field narrowing and
  container covariance, so cast-foreclosure holds against real code,
  not only a trivial one-file script.

**alongside, not gating the above:**

- **child-process spawning**, `cosmic.child` over `posix_spawn`.
  serves two things at once once it lands: the isolation layer the
  test runner still lacks (a hang or a crash in one test currently
  takes down the whole run), and the re-exec the stale-tool refusal
  needs (it detects a stale tool and refuses today; it has no
  process yet to re-exec into).
- **the provenance gate**: no bytes from outside the tree and the
  pinned zig reach an output, checked by building on two hosts and
  comparing hashes.
- **`O_CLOEXEC` on the remaining `fopen` paths** in boot and the
  patch applier; the syscall table's own `open` already sets it.
- **a fuzzer over the executable locator**, now that it parses
  untrusted bytes at every startup.

## the release bar

the core tier, then the second, each module earning its place. a
release ships when three things hold: cosmic builds and tests the
work board, gitboard, from its own tree; the agent evaluation suite
scores at or above its recorded baseline; the release job produces
all three targets and the repro lane proves them byte-identical.

## open questions

- **host language and toolchain.** Rust as the host was weighed and
  deferred early on; zig as the language was set aside. revisit now
  that a real C core and build.zig exist to compare against, not a
  sketch.
- **FTS5.** measured at 222 KB per core image, three images per
  binary, from the current size report. the decision itself is
  still open, and belongs to whoever needs full-text search first.
- **an address-sanitized lane** on a clang outside the pinned
  toolchain. deferred until the C core is large enough to want it;
  today's core is a few files and hasn't earned the second toolchain
  yet.
