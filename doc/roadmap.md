# roadmap

this file records remaining work and open decisions only. [design.md](design.md)
defines the target; once something ships, it leaves this file.

"old" below is the previous tree, kept on the `old` branch (at `96da34e7`):
`git show origin/old:<path>` reads a file it names.

## language and self-check

- implement the cast policy in design.md. a cast is legal only from `any`, from
  a userdata record declared in `.d.tl`, or from the enclosing generic's type
  variable. none of `patch/tl` enforces it yet, and the tree's own Teal holds
  about seventy `as` casts to migrate or justify first. old's
  `3p/tl/tl_patch/cast.tl` and `docs/design/cast-legality.md` are useful
  implementation and migration evidence.
- add earned lint rules and their fixes to `build/fix/rule.tl`'s rule list.
  the rewrite stage is in place and the list is still empty.
- add a floor for line coverage, C included: `cosmic test --min PCT
  [--min-file PCT]` fails a whole run whose overall or any one file's line
  coverage falls below it, naming each file under the per-file floor with its
  percentage; with neither flag it reports and passes, as today. every release
  core and the sanitized core already observe their own C, in the processes a
  test starts too, into the same `coverage` table as Teal's (`core/coverage.c`),
  and a run already fails for any C function no test enters
  (`build/c_functions.tl`); the floor is what catches lines going untested
  inside a function a test does enter. CI states the floor at the call site
  rather than in a committed ratchet file. old's #1778
  (`_tool/coverage/minimum.tl`, `--make coverage --min PCT --min-file PCT`,
  which replaced the `.cosmic-coverage` ratchet and its `--baseline`) and #1781
  (`pr.yml`'s `--min 76 --min-file 0`) are the model.
- add a sensitivity record for coverage gates' host-dependent lines. old's
  `cosmic/coverage/SENSITIVITY.md` is a useful model: establish a floor from CI
  measurements and record why root access, a terminal, a free port, or a
  platform feature changes it.

## untrusted input

design.md promises that the parsers facing untrusted input are fuzzed.
`build.fuzz` runs the tar, zip and archive properties and the host-program
locator's on every `cosmic test`, and CI reruns them deep on the checked core.
curl and c-ares are fuzzed upstream; record that as their evidence rather
than fuzzing them here.

- fuzz the portable launch. `build/locator_fuzz_test.tl` covers a host
  program's trailer and manifest, which share `decode_blocks` with a portable
  artifact, but not the launcher's own reading of the shell header or the core
  a portable start adopts from the cache.
- publish `cosmic-debug`, the sanitized build, once there is a way to
  distribute one fat, cross-platform debug build. until then the checked core
  is built and run only in CI, where its build paths do not matter. the core
  links its host's libc and carries build paths in `.rodata` and its line
  tables, so a published one would be built at a fixed path on every runner.

## process isolation and containment

Contain a dead worker's escaped descendants on macOS. Linux adopts them as a
child subreaper and `Child.end_strays` ends them; macOS has no subreaper, so a
process group a timed-out test started for itself is left to launchd.

Add build and test sandbox fencing: a `cosmic.sandbox` module and conformance
matrix implementing the portable policy in design.md, required in CI, with
degraded or skipped enforcement reported on hosts that cannot provide a section.
`cosmic.http` now gives the core network egress, which makes the fence's
network section matter sooner.

Per-host egress policy is a separate Linux extension. Landlock can restrict a
port but not a remote address. old's `cosmic/quicksand/` is a reference for a
network namespace, guarded proxy, and declarative child runner; it should not
be folded into the portable sandbox contract.

Open the remaining `fopen` paths with `O_CLOEXEC` (`"e"` in the mode):
`core/boot.c`'s read and `core/patch.c`'s read and write.

## surface

design.md's core tier names modules the tree does not have yet. the ones the
promises lean on come first:

- `shape` and `json`: design.md's principle 4 has untrusted data enter through
  a declared shape, and there is no shape validator or JSON codec to do it.
  JSON starts in Teal and is measured against a C implementation once the
  benchmark harness exists.
- `flags`, `log`, `string`, `format`, `check`: small modules a program
  otherwise hand-rolls.
- `ast`, `teal`, `test`, `doc` and `embed` exist only as build internals under
  `build/`. decide which become public `cosmic.*` modules and what a program
  gets from each.

## documentation and examples

New documentation extends the one build-time index and runtime query path
behind `cosmic docs` and `cosmic uses`; API guidance goes in the indexed doc
comment beside the source, and a guide is only for a task larger than one
symbol.

- add focused `*_example.tl` files beside `sys`, `hash`, `sqlite` and `removed`'s:
  filesystem, environment, process, time, errors, and store first, then
  `http`, `archive` (with `tar`, `zip` and `stream`), compression, and
  coverage.
- add mention search for prose references that `cosmic uses` cannot see.
  old's `cosmic/doc/mentions.tl` demonstrates the separate full-text query.
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
  partial, and fail fixtures. `notes` is still the only task. The next should
  exercise a different part of the library (child processes, the store,
  compression, or now `http` and archives) so one task's friction is not
  mistaken for the whole product's. old's `_eval/` is a reference for keeping
  briefs, graders, their registry, and golden run directories consistent.
- add a performance gate once stable comparison targets exist. It should
  re-measure a suspected regression against one baseline, run an A/A noise
  check, and use a third reading to break a tie. old's `_perf/gate.tl`,
  `compare.tl`, `reproduce.tl`, and `tiebreak.tl` show this shape. The same
  harness is what design.md says moves a module across the C/Teal line.

## open decisions

- **host language and toolchain.** Re-evaluate the current C core and pinned Zig
  build against Rust, Zig as the implementation language, and old's vendored
  Cosmopolitan approach. Include size, portability, reproducibility, patch
  ownership, and failure consistency. `bin/zig` and `bin/vendor` now run on a
  pinned bootstrap cosmic, so the build driver is already self-hosted while the
  compiler is not; that is evidence, not the answer. Do not assume full
  self-hosting is the desired answer before comparing the maintained systems.
- **DNS and HTTP in C.** design.md's C/Teal line still says DNS is a Teal
  resolver and HTTP/1.1 framing enters C only on a benchmark, while
  `cosmic.http` shipped as curl over c-ares and mbedtls. Either amend that
  paragraph to record why curl and c-ares met the bar (fuzzed upstream, TLS
  needed now), or plan the Teal resolver and decide what then remains in C.
- **sanitizer tier.** The Linux lane already runs the whole suite on a checked
  core (ReleaseSafe, full undefined-behavior checking, Lua's own assertions),
  the static analyzer, and a walk of every allocation-failure path. What is
  missing is memory-safety checking: zig ships no address sanitizer, so that
  lane needs a compiler outside the pinned production toolchain. curl, c-ares
  and mbedtls's TLS layer grew the C that faces the network; decide whether
  that is the size that justifies the lane, and keep its evidence separate from
  reproducible release production.
- **target tiers.** design.md lists core, second and later tiers; define what
  test, documentation, portability, and maintenance evidence promotes a module
  from one to the next, and whether a second-tier module that shipped ahead of
  the core tier (`http`, `tar`, `zip`, `stream`) is held to the same bar.
- **decision records.** Adopt a small durable format before resolved questions
  disappear from this file. Record context, the decision, rejected alternatives,
  and consequences; amend a record when the decision changes.
