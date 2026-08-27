## Evidence

`_perf/skew_test.tl` type-checks every non-test `_perf/**` file under
the pinned bootstrap, to move a bare-load failure onto the PR that
introduces it. The failure class is real and was real when the guard
landed (`run.tl`'s `version_info` read killed the 2026-08-26 release
run; `literal_bench`'s two-argument `literal.format` would have killed
the next). The question this item asks is whether any release lane can
still trip it.

3IVF3HbV converted `release.yml`'s compare step from a bare run to a
`--modules` run, and justified keeping the guard on the grounds that
the `peers` job is still a bare load under an older binary. **That
justification is half wrong.** `peers` has `needs: build` and downloads
the `cosmic-lua` artifact produced by THIS RUN's `build` job, so the
binary it runs `_perf/peers/run.tl` under is built from the same
checkout. Its embedded `cosmic.*` declarations equal the tree's by
construction. The bare SHAPE is there; the version skew is not.

So after 3IVF3HbV, what keeps the guard live is narrower than either
its old docstring or its new one implies:

- a `--modules` run that falls through to `tree_searcher`'s third step
  — source, strict-compiled (`cosmic/searcher.tl:367`) — because a
  prebuilt `o/<path>.lua` is missing;
- anyone running the tree's `_perf` under a downloaded OLDER release by
  hand.

Neither is a release lane. The guard costs a full type-check of every
`_perf` source on every `--make ci` run — it is the kind of check that
should be able to name the lane it protects.

## What this item must settle

Whether the guard earns its cost now, and that is a real question with
three honest answers rather than a foregone one:

1. **Keep it, and say what it guards.** The hand-run case is genuine —
   a contributor measuring the tree against a downloaded older release
   is exactly the workflow `skills/optimize/measurement.md` teaches for
   cross-session reproduction, and it would fail confusingly without
   the guard. If this is the answer, the header should name that
   workflow rather than a lane.
2. **Retire it**, if the measured cost is real and no path that
   matters can trip it. Measure the cost first: time
   `bin/cosmic --make test _perf/skew_test.tl` against the gate's
   total.
3. **Point it at the lane that does have skew.** 3IVF3HbV's own
   `## What this newly exposes` names one: the tree's `cosmic.*` Lua
   now runs on the previous release's `cosmo.*` C bindings on the
   baseline side, and nothing guards that. A guard aimed there would
   protect a live release lane, which the current one no longer does.

Answer 3 is the one worth weighing first, because it is the only one
that leaves a release lane better guarded than it is today. Do not
retire anything before measuring the cost that motivates retiring it.
