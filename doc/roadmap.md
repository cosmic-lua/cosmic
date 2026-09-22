# roadmap

this file records remaining work and open decisions. [design.md](design.md)
defines the target. current behavior is named here only where it distinguishes
an unfinished step from an existing foundation.

## language and self-check

`cosmic test`, doctests, Lua and Teal coverage, the structural AST, and the
`cosmic fix` pipeline exist. the next language work is narrow:

- implement the cast policy in design.md. a cast is legal only from `any`, from
  a userdata record declared in `.d.tl`, or from the enclosing generic's type
  variable. main's `3p/tl/tl_patch/cast.tl` and
  `docs/design/cast-legality.md` are useful implementation and migration
  evidence.
- add earned lint rules and their fixes. the parse, structural match, rewrite,
  comment-preservation, render, and equivalence framework already exists under
  `build/ast/` and `build/fix/`; the rule list is the unfinished part.
- keep sibling privacy as a compile-time rule. case-collision rejection is a
  closed, dropped proposal. container covariance is also dropped; no current
  use requires it. record-field narrowing already exists in the patches
  `patch/tl/07-assert-narrows.txt` through
  `patch/tl/14-narrow-record-field-eval-fact.txt`.

C tests and C coverage remain deferred, not dropped. They should use the same
discovery and command as Lua and Teal tests, with one combined report. The
current implementation direction is LLVM source coverage for `core/*.c`, a
vendored profile runtime for each target, and `llvm-profdata` and `llvm-cov`
matched to the pinned Zig LLVM version. Lua and Teal testing no longer block
this work; its cost and integration design do.

Coverage gates also need an explicit sensitivity record for host-dependent
lines. main's `cosmic/coverage/SENSITIVITY.md` is a useful model: establish a
floor from CI measurements and record why root access, a terminal, a free port,
or a platform feature changes it.

## process isolation and containment

`cosmic.child` already provides `posix_spawn`, redirection to caller-owned file
descriptors, bounded waits, process-group cleanup, and reap-on-drop behavior.
It does not collect output. `cosmic test` does not yet use it: tests still run
in the build process.

Run each test in a child with a fresh temporary directory, captured streams,
and a per-test deadline. The child must not open the build database; it reports
a result to the build process, which alone records the verdict. A command-level
budget measures total suite time but cannot replace the per-test deadline that
kills a hung test. The intended controls are `--timeout SECONDS` and an
environment-variable default; choose the variable's name when the runner can
enforce it.

Build and test sandbox fencing is also target behavior. There is no
`cosmic.sandbox` module or conformance matrix in this tree yet. Implement the
portable policy in design.md first, then require it in CI and report degraded or
skipped enforcement on hosts that cannot provide a section.

Per-host egress policy remains a separate Linux extension. Landlock can restrict
a port but not a remote address. main's `cosmic/quicksand/` is a reference for
a network namespace, guarded proxy, and declarative child runner; it should not
be folded into the portable sandbox contract.

Add a seeded, shrinking fuzzer for the executable locator. The proposed
framework uses `FUZZ_SEED` and `FUZZ_ITERS`, runs iterations in isolated
children for crash containment, and uses an instruction budget as the hang
backstop. main's `_fuzz/` is the reference. Also finish `O_CLOEXEC` coverage on
the remaining `fopen` paths in boot and the patch applier.

## documentation and examples

`cosmic docs` and `cosmic uses` already query the shipped `docs`, `uses`, and
`examples` records. Lookup includes fuzzy full-text search, and diagnostics can
point to matching documentation. Preserve that one build-time index and one
runtime query path as documentation grows; do not build another documentation
system beside it. main's `cosmic/doc/` and `_tool/doc/` remain useful references
for query and extraction behavior.

Put API guidance in the indexed doc comment beside the source. A new guide is
for a larger task that cannot stand alone at one symbol, not for restating an
API comment.

Add focused `*_example.tl` files for public APIs that lack them. Hash and SQLite
already have examples. The immediate gaps are filesystem, environment, process,
time, errors, and store. Compression and coverage examples remain deferred
behind that immediate set.

Add mention search for prose references that `cosmic uses` cannot see. main's
`cosmic/doc/mentions.tl` demonstrates the separate full-text query. Decide
whether README's runnable-looking shell example moves into `doc/guides/`, where
the doctest extractor enforces it, or remains an explicit manual exception.

main's `env.d/` credential convention and `_docs/derive.tl` derived-markdown
mechanism remain references for later needs, not current roadmap commitments.

## release evidence

The release bar remains three checks: Cosmic builds and tests gitboard from its
own tree; `eval/` passes the task's grader under `eval/check/<task>`; and the
release product covers all three targets with byte agreement proved by the
four-producer provenance join. The gitboard check still needs concrete
interpretation:

- decide what “builds and tests gitboard from its own tree” means. A separately
  pinned gitboard, as on main, proves a different property from building its
  source here. Write the check only after choosing the property.
- grow `eval/` into a fixed task suite with tested graders and known pass,
  partial, and fail fixtures. main's `_eval/` is a reference for keeping briefs,
  graders, their registry, and golden run directories consistent.

A performance gate is future work once stable comparison targets exist. It
should re-measure a suspected regression against one baseline, run an A/A noise
check, and use a third reading to break a tie. main's `_perf/gate.tl`,
`compare.tl`, `reproduce.tl`, and `tiebreak.tl` show this shape.

## open decisions

- **host language and toolchain.** Re-evaluate the current C core and pinned Zig
  build against Rust, Zig as the implementation language, and main's vendored
  Cosmopolitan approach. Include size, portability, reproducibility, patch
  ownership, and failure consistency. Do not assume self-hosting is the desired
  answer before comparing the maintained systems.
- **sanitizer tier.** Decide when the C core is large enough to justify an
  address-sanitized lane using a compiler outside the pinned production
  toolchain. Keep that evidence separate from reproducible release production.
- **target tiers.** Define which modules belong in the core and later tiers, and
  what test, documentation, portability, and maintenance evidence promotes one.
- **decision records.** Adopt a small durable format before resolved questions
  disappear from this file. Record context, the decision, rejected alternatives,
  and consequences; amend a record when the decision changes.
