# roadmap

what comes after the current state in [design.md](design.md), and
the questions still open. this doc is read alongside design.md, not
instead of it: design.md says what cosmic is, this says what is
next and what is undecided.

## self-check

`cosmic test` compiles what changed in the tree with the patched Teal
checker, reads the rest back from the working database, and runs, in
process, every discovered test whose stored verdict does not stand,
with records in that same database. the planned restriction on casts
is not yet implemented.
tests, the in-process runner, and a real Teal AST (`build.ast`:
parse, walk, structural match, rewrite) have already landed; what
follows leans on `build.ast`, still build-internal today, and on
`o/build.db`, which already holds test verdicts.

there is no separate `cosmic check` verb, and none is planned:
type and visibility checking run on every `cosmic test` and plain
`cosmic file.tl` invocation. `cosmic fix` parses, rewrites, renders,
and checks the rendered AST and comments against the rewritten input;
it does not run type or visibility checking. `build/
importer.tl`'s `complain()` folds syntax errors, type errors, and
warnings into one list, and any of them refuses the whole compile --
remaining compiler warnings are errors on these compile paths
(the importer filters unused discovered test functions and generated
doctest `print` shadowing warnings). `build/positions.tl`'s
sibling-privacy check runs the same way, on every compile -- see the
visibility lint entry below, which this same mechanism already closes.

- **the doctest extractor has landed** (`build/doctest/`: `markdown.tl`
  parses fenced blocks, `generate.tl` turns them into one compiled Teal
  file per doc, one function per example), and is wired straight into
  `build/importer.tl`'s ordinary collection: `doc/guides/*.md` is
  discovered and run through it exactly like a hand-written `_test.tl`,
  needing no runner of its own, per meta.md. Live today, not
  hypothetical -- `doc/guides/quickstart.md` compiles and runs as
  `doc.guides.quickstart`, and CI's own step name already says "run
  every test the tree defines, including doctests".
- **Lua and Teal coverage has landed** (`cosmic/coverage.tl`), and so
  has the collector cheap enough to leave on by default: a line hook
  that keeps its own hit accounting in C (`core/coverage.c`), one
  `lua_getinfo` call filling `currentline`/`short_src` straight into a
  C struct and a table write, no Lua closure and no `debug.getinfo`
  call from Lua on the hot path -- the earlier Lua-side hook this
  replaced cost exactly that call per line the whole suite executed,
  which was minutes on this tree; `build.test` now runs it on every
  `cosmic test` and reports a real percentage. `debug` itself stays
  out of reach the same way it always has, for reasons that are not
  this module's; nothing fetches it back out any more.

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

- **cosmic's own stdlib resolves from outside its tree** -- landed:
  the binary ships every `cosmic.*` source and declaration as rows
  (`decls` beside `modules`), and the checker's module search falls
  through to them for a name the project's own stage does not hold,
  so `require("cosmic.fs")` in a project that is not cosmic's own
  checkout compiles, is typed, and runs, with nothing of this repo on
  disk. This, not a missing verb, is what "a real project imports
  more than a trivial one-file script" was actually pointing at.
- **the rewrite rules `cosmic fix` applies.** the verb has landed, and
  with it the renderer that writes a parsed tree back out as source; its
  rule list is empty, because the rules worth writing are lint fixes and
  the lint rules have not yet been implemented. adding one is the whole
  cost of a new fix: no part of the pipeline moves around it.
- **the visibility lint has landed**, and turned out to already be
  built: `build/positions.tl`'s sibling-privacy check -- a directory
  with its own `init.tl` is private, only a file inside it may
  require a sibling beside that entry, generalized to every directory
  in the tree, not only `cosmic`'s own reserved namespaces -- already
  runs on every compile, and `test/visibility_test.tl` already proves
  it. The case-collision half (no two names in a directory differing
  only in case) is dropped, not merely deferred -- nothing about it
  is currently planned.
- **record-field narrowing has landed** (`patch/tl/08` through `14`,
  plus the bare-variable statement-form `assert` narrow it builds on,
  `07-assert-narrows.txt`): a guard on `x.field` -- truthy read,
  `assert`, `== nil` / `~= nil`, the early-return shape -- narrows the
  field the same way a bare variable already narrows, on a
  bare-variable base only (`a.b.field` does not chain). container
  covariance, once considered the other remaining narrowing patch, is
  dropped, not deferred: no v1 precedent ever needed it, against a far
  larger codebase, and no evidence of a live blocker has ever turned up
  in this tree either -- a hypothetical with nothing behind it, not a
  known gap.

**alongside, not gating the above:**

- **child-process spawning**, `cosmic.child` over `posix_spawn`.
  serves three things at once once it lands: the isolation layer the
  test runner still lacks (a hang or a crash in one test currently
  takes down the whole run), the re-exec the stale-tool refusal
  needs (it detects a stale tool and refuses today; it has no
  process yet to re-exec into), and a real default time limit on
  `cosmic test` (something like 30 seconds) that can actually kill a
  hung test rather than just watch it: a cooperative, checked-between-
  tests budget was considered and set aside deliberately, since it
  cannot preempt one single test stuck in a genuine infinite loop
  mid-execution -- exactly the failure a timeout exists to catch --
  it can only notice aggregate slowdown after the fact, which
  `cosmic test`'s own verdict line (pass/fail plus wall-clock-visible
  slowness) already surfaces well enough. Worth a CLI flag
  (`--timeout SECONDS`) and an env var default, once there is a
  process to actually kill.
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
