# roadmap

this file records remaining work and open decisions only. [design.md](design.md)
defines the target; once something ships, it leaves this file.

## language and self-check

- implement the cast policy in design.md. a cast is legal only from `any`, from
  a userdata record declared in `.d.tl`, or from the enclosing generic's type
  variable. main's `3p/tl/tl_patch/cast.tl` and
  `docs/design/cast-legality.md` are useful implementation and migration
  evidence.
- add earned lint rules and their fixes to `build/fix/rule.tl`'s rule list.
- make the checker choose an overload by the number of values a multi-value
  last argument expands to. `tonumber(assert(Fs.read(p)))` checks against
  `tonumber(any)` while the `""` error slot reaches `base` at run time; a
  function that is not overloaded already refuses the same spill.
- add C tests and C coverage. They should use the same discovery and command as
  Lua and Teal tests, with one combined report. The current direction is LLVM
  source coverage for `core/*.c`, a vendored profile runtime for each target,
  and `llvm-profdata` and `llvm-cov` matched to the pinned Zig LLVM version.
  Cost and integration design are what block it.
- add a sensitivity record for coverage gates' host-dependent lines. main's
  `cosmic/coverage/SENSITIVITY.md` is a useful model: establish a floor from CI
  measurements and record why root access, a terminal, a free port, or a
  platform feature changes it.

## process isolation and containment

Make the first launch cheap too. A process relaunching itself (`Proc.relaunch`,
which test workers use) already skips the shell launcher, but every launch from
a shell still pays for its `uname`, `id`, `stat`, and `sha256sum` steps: about
23 ms of the roughly 43 ms a minimal start takes. Trim the launcher, and add a
host-only "assimilated" program -- the native core with the database appended,
executed directly -- for hosts that want no launcher at all.

Contain a dead worker's escaped descendants on macOS. Linux adopts them as a
child subreaper and `Child.end_strays` ends them; macOS has no subreaper, so a
process group a timed-out test started for itself is left to launchd.

Add build and test sandbox fencing: a `cosmic.sandbox` module and conformance
matrix implementing the portable policy in design.md, required in CI, with
degraded or skipped enforcement reported on hosts that cannot provide a section.

Per-host egress policy is a separate Linux extension. Landlock can restrict a
port but not a remote address. main's `cosmic/quicksand/` is a reference for a
network namespace, guarded proxy, and declarative child runner; it should not
be folded into the portable sandbox contract.

Add a seeded, shrinking fuzzer for the executable locator. The proposed
framework uses `FUZZ_SEED` and `FUZZ_ITERS`, runs iterations in isolated
children for crash containment, and uses an instruction budget as the hang
backstop. main's `_fuzz/` is the reference.

Open the remaining `fopen` paths in `core/boot.c` and `core/patch.c` with
`O_CLOEXEC`.

## documentation and examples

New documentation extends the one build-time index and runtime query path
behind `cosmic docs` and `cosmic uses`; API guidance goes in the indexed doc
comment beside the source, and a guide is only for a task larger than one
symbol.

- add focused `*_example.tl` files for filesystem, environment, process, time,
  errors, and store. Compression and coverage examples follow that set.
- add mention search for prose references that `cosmic uses` cannot see.
  main's `cosmic/doc/mentions.tl` demonstrates the separate full-text query.
- decide whether README's runnable-looking shell example moves into
  `doc/guides/`, where the doctest extractor enforces it, or remains an
  explicit manual exception.

## release evidence

The release bar is three checks: Cosmic builds and tests gitboard from its own
tree; `eval/` passes the task's grader under `eval/check/<task>`; and the
release product covers all three targets with byte agreement proved by the
four-producer provenance join.

- decide what “builds and tests gitboard from its own tree” means. A separately
  pinned gitboard, as on main, proves a different property from building its
  source here. Write the check only after choosing the property.
- grow `eval/` into a fixed task suite with tested graders and known pass,
  partial, and fail fixtures. The next task should exercise a different part
  of the library than notes (child processes, the store or compression) so one
  task's friction is not mistaken for the whole product's. main's `_eval/` is a
  reference for keeping briefs, graders, their registry, and golden run
  directories consistent.
- add a performance gate once stable comparison targets exist. It should
  re-measure a suspected regression against one baseline, run an A/A noise
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
