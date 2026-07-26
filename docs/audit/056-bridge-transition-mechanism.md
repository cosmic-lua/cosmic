# 056 — bridge removal: the transition needs a dual gate and a disposition table

severity: blocker for 3i (the mechanism the other five run inside)
type: process / verification
area: Makefile, mk/*.mk, cook.mk, pr.yml, `_build/makefile_ratchet_test.tl`

## one unverified assumption to retire first

1. **nobody has shown `--make test` passes this repo's full suite.**
   the plan says it "runs today" and 3f wired the closures, but no CI
   lane runs it and no log records a full green run. before anything
   is deleted, run `cosmic --make test` over the whole tree and fix
   what differs — test *discovery* parity (same test set as
   `bin/make test`, including `.lua` tests since 4a15b92) is as
   important as pass/fail parity.

(the second assumption — graph tests skipping silently without the
engine, audit 029 — is retired: 629a117's `check.needs` hard-fails in
CI, and its very first CI run caught the 027 payload gate skipping in
every prior run, 11343a6. that is the empirical case for this file's
dual-gate discipline: gates that cannot report their own absence go
quietly decorative.)

## progress since filed

3e94a02 gated the fixpoint (audit 026) as a *test* in the existing
lanes — the right mechanism, and it retires the worst of the "looks
green while broken" risk for `build`. one transition detail it adds:
the test seeds `o/3p/**` from what the **Makefile pipeline** staged,
deliberately, to stay offline. when the bridge goes, that seeding must
switch to `--make fetch` — which makes 028 a prerequisite of the final
deletion, not just a nice-to-have.

## the dual gate

add a pr.yml lane running `cosmic --make ci` (as its stages land, 051)
**beside** `bin/make ci`, both required. every bridge-removal slice
lands behind both gates green — the same "each slice lands behind the
existing build" discipline phase 3 used, now with the replacement
also gating. the lane starts as `check` + `test` + `build` today and
grows a stage per 051 delivery; the Makefile's gate is deleted only
when the two have been redundant for a full cycle.

## the disposition table

every `##`-documented target gets one recorded fate before deletion —
the inventory (Makefile, mk/*.mk, cook.mk, module cook.mks):

| fate | targets |
|---|---|
| verb, exists | build, test, clean, fetch/staged, format→fmt, teal→check |
| verb, needed (051/054) | ci, example, lint, coverage, coverage-baseline, regen-types→regen, docs/doc-publish, benchmark/perf* |
| dissolves | model (is `check`), facts (the graph is the facts), bootstrap (055), help (usage/skills) |
| stays outside the build | doc-publish's git push (workflow step), perf harness orchestration if not a verb — decide, don't drop |

`_perf`'s targets (perf, perf-baseline, perf-compare, perf-bin,
benchmark) are the easiest to lose accidentally: no CI lane runs them,
so nothing fails when they break. decide their home (a `bench` verb, or
plain `cosmic` script invocations documented in `_perf/OPTIMIZE.md`)
as part of the table, not after the Makefile is gone.

## deletion order (dependencies, not preference)

029 hard-fail → dual gate lane → 051 verbs (gate parity) → 054
regen/docs (pin-bump workflow) → 052 fence default (enforcement
parity) → 053 release parity → 055 trust-root swap → delete Makefile,
mk/, cook.mk, `-include` bridge, `_build/build-fetch.tl` (030), the
`--build` flag (031), and `makefile_ratchet_test.tl` — the ratchet
retires *with* the file it guards, last.
