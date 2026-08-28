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

## Resolution — measured 2026-08-28, ended not-planned

The premise in the title is false, and so is the premise of answer 3.
Both were checked against `origin/main` `40776231` (#1488 merged), by
reading every release lane end to end rather than by reasoning from
the peers job.

**Every `release.yml` lane that loads `_perf`, and whose binary loads
it** (`git show origin/main:.github/workflows/release.yml`):

- `build` / "measure the release" (`:133-140`) —
  `o/bin/cosmic --make run _perf/run.tl` twice. This run's own binary,
  tree resolution. No skew.
- `build` / "compare against the previous release" (`:167-200`) —
  `_perf/baseline.tl`, `_perf/baserun.tl` and `_perf/gate.tl compare`
  all under `o/bin/cosmic --make run`, but `_perf/baserun.tl` SPAWNS
  `o/perf/prev/cosmic-lua --modules <manifest> o/_perf/run.lua`
  (`_perf/baserun.tl:40,126`, invoked at `release.yml:184`). **This is
  a live skew lane: the previous release's binary loading the TREE's
  `_perf`.** `_perf/gate.tl:388-414` routes the regression retry
  through the same `baserun.argv`, so the retry that decides the gate
  is the same lane again.
- `peers` (`:273-309`) — bare `./dl/cosmic-lua _perf/peers/run.tl`, on
  this run's own `cosmic-lua` artifact (`needs: build` `:274`,
  download `:280-283`, uploaded from `o/bin/cosmic` `:237-247`). No
  skew; `test_the_peers_lane_measures_this_runs_own_binary`
  (`_build/workflows_test.tl:394`) now holds that shape (3IVJI3ZS).
- `release` (`:318-378`) — downloads and publishes; loads no `_perf`.

So one release lane loads the tree's `_perf` under an older binary,
and it is exactly the lane `_perf/skew_test.tl:2-14` already names —
"release.yml's compare step measures the previous release binary
against the TREE's `_perf` (`_perf/baserun.tl`)". 3IVF3HbV's own spec
says the same in *What this changes about the gate's meaning*, point
3: the guard "becomes MORE load-bearing after this change, not less".
The peers observation this item was opened on is true and was already
3IVF3HbV's Evidence 5; it was never what kept the guard alive.

**Answer 3 rests on a misreading.** Under the `_perf`-scoped root the
tree's `cosmic.*` is NOT loaded on the baseline side — 3IVF3HbV's
Evidence 1 measured `cosmic.json @/zip/cosmic/json.lua` and
`cosmic.teal @/zip/cosmic/teal.lua` under the scoped root, i.e. the
baseline binary's own. There is no "tree `cosmic` on old `cosmo`"
surface to point a guard at. The only tree code the baseline side
loads is `_perf/**`, which is what the guard checks.

**The conversion widened what the guard is the only detector for.**
The manifest root serves prebuilt Lua first
(`<root>/<build>/<rel>.lua`, `_perf/baserun.tl:15-20`) and all 18
bench modules plus the entry are built (`ls o/_perf/bench/*.lua` → 18;
entry `o/_perf/run.lua`, `_perf/baserun.tl:40`), so the baseline side
type-checks nothing. Before the conversion, a `_perf` arity change
(#1420's two-argument `literal.format`) was a load-time type error
that killed the lane loudly. Under prebuilt Lua the same change is
silent — Lua ignores extra arguments — and would publish a baseline
number measured with the wrong layout. `_perf/skew_test.tl` is now the
only thing that catches that class at all.

**Answer 2 is refuted without needing its cost measurement.** Retiring
requires "no path that matters can trip it", which is false. The cost
timing this item asked for was therefore not run, and is not what
decides the question.

Answer 1 is the answer, and the tree already holds it:
`_perf/skew_test.tl:1-36` names the compare lane, `_perf/baserun.tl`
and the two readings of a failure. Nothing left to build.
