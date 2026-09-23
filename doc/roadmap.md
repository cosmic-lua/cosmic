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
- add a floor for line coverage, C included: `cosmic test --min PCT
  [--min-file PCT]` fails a whole run whose overall or any one file's line
  coverage falls below it, naming each file under the per-file floor with its
  percentage; with neither flag it reports and passes, as today. C lines are
  already in the same `coverage` table as Teal's (`core/coverage.c`), and a run
  already fails for any C function no test enters (`build/c_functions.tl`);
  the floor is what catches lines going untested inside a function a test
  does enter. CI states the floor at the call site rather than in a committed
  ratchet file. main's #1778 (`_tool/coverage/minimum.tl`, `--make coverage
  --min PCT --min-file PCT`, which replaced the `.cosmic-coverage` ratchet and
  its `--baseline`) and #1781 (`pr.yml`'s `--min 76 --min-file 0`) are the
  model.
- add a sensitivity record for coverage gates' host-dependent lines. main's
  `cosmic/coverage/SENSITIVITY.md` is a useful model: establish a floor from CI
  measurements and record why root access, a terminal, a free port, or a
  platform feature changes it.

## process isolation and containment

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

Fuzz the portable launch. `build/locator_fuzz_test.tl` covers a host
program's trailer and manifest, which share `decode_blocks` with a portable
artifact, but not the launcher's own reading of the shell header or the core
a portable start adopts from the cache.

Publish `cosmic-debug`, the sanitized build, beside the release. The fuzzers
it waited on run in CI (the checked core's deep run), but the unstripped core
still carries build paths: the checkout's in `.rodata`, where the
undefined-behavior checks keep their source locations, and in its line
tables, and zig's library directory in the line tables of the musl and
compiler-rt it compiles, which no flag of ours reaches. Decide between
`-ffile-prefix-map` plus debug info without those paths, and no debug info,
before the asset is added to `prerelease.yml`.

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
