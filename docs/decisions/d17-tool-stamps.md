# D17 — a graph rule's tool prerequisite is a per-tool stamp, not the binary

- **date:** 2026-08
- **context:** every graph rule named the running binary
  (`$(COSMIC_DEP)`) as a prerequisite, because a result is only as
  fresh as the tool that produced it — a formatter fix must invalidate
  every `.fmt.got`, or a tree reports clean against the formatter it
  replaced. But the binary embeds every module in the tree, so the rule
  conflated the tool's identity with the artifact's: editing ANY
  embedded module produced a new binary, which invalidated EVERY
  compile, fmt, lint, test, example and coverage result. Measured on
  this repo (4 cores): a one-line edit to a module with four importers
  cost a full 394-file recompile plus all 182 tests — 2 minutes wall,
  6 CPU-minutes — where its closure costs seconds. The same coupling
  produced the "echo build" (the artifact replaced at a build's end was
  newer than every output, so the next build recompiled the world to
  prove nothing changed) and two of the three full builds CI paid
  before its first gate stage.
- **decision:** the tool a rule depends on is the set of embedded
  bytes that RUN when the rule's verb runs. `materialize` writes one
  stamp file per tool — `o/.stamp/{compile,driver,fmt,lint,record}` —
  hashing the running binary's own `/zip` copies of that tool's module
  closure (walked by the model's require-scanner), the measured boot
  surface every child pays (ratcheted against a live child by
  `stamp_test`), the vendored `tl.lua` where the tool reads it, and the
  tree's `*_pin.tl` bytes, so a pin bump still invalidates everything.
  Stamps are write-if-changed; the constant rules name them instead of
  the binary. A binary missing a tool's root modules falls back to
  hashing the whole binary — the old behavior, kept for artifacts that
  stripped the toolchain.
- **rejected:** keeping `COSMIC_DEP` (the measured cascade above; it
  taxed exactly the loop — small edit, narrow re-test — the closures in
  `o/project.mk` exist to serve); hashing tree sources instead of
  embedded bytes (behavior comes from what is embedded — a gate that
  just converged runs the tree's bytes, and a pinned release driving a
  cold tree does not); tying `record` to the dispatcher's full static
  closure (the dispatcher requires the rest of the tree lazily, so its
  static closure is nearly the binary again — the cascade wearing a new
  name); a per-step action cache keyed on argv + input hashes
  (`engine.md` names it; it subsumes this but is a much larger change,
  and stamps deliver the measured win with make's own scheduling).
- **consequences:** an edit re-runs its import closure and the
  verdicts about it, not the world; the echo build is gone (the
  replaced artifact is no longer a prerequisite of anything). A
  formatter fix still re-runs every fmt verdict — its closure hash
  moved — and a compiler or pin change still recompiles everything.
  The traded edge, stated: a test that SPAWNS the binary and exercises
  engine code it does not import (a fixture test driving `--make`
  through a `_make` module it never requires) keeps its recorded
  result until its own closure or the record tool moves; CI is immune
  (it runs cold), and engine work runs the `_make` tests by path. The
  boot list in `_make/stamp.tl` is a measured fact with a live-child
  ratchet, so it can drift wide (harmless) but never silently narrow.
