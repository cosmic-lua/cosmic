Imported from whilp/cosmic#1228.

## Goal

G4 — "a gate's PASS means something", and G1's no-silent-bugs anchor. The
coverage ratchet is the committed floor that makes a coverage claim binding. It
has two failure modes that both end with a floor nobody can trust and nobody can
repair, and in both the tool's own printed remedy makes it worse.

Named as unfiled in #1200's own `## Enablement` section ("a `--baseline` refusal
on a partial `.cov` corpus"). Observed twice today, independently, during the
reviews of PR #1195 and PR #1214.

## Evidence

**1. `--baseline` will freeze a garbage floor when the `.cov` corpus is partial
or stale, and it tells you to do exactly that.** Reviewing PR #1214 against a
copied `o/` produced:

```
coverage declined 73.5% -> 14.9% ... 140 problem(s)
```

with an instruction to run `bin/cosmic --make coverage --baseline`. Followed
literally, that command commits a 14.9% floor as the project's permanent
guarantee. Nothing in the failure message distinguishes "your tests genuinely
stopped covering this" from "you measured almost nothing". D18's content-keyed
skips make a partial corpus an ordinary outcome, not an exotic one.

**2. A wrongly-low row is permanent — the ratchet is a one-way valve with no
repair path.** `_tool/coverage/baseline.tl:82-84`:

```teal
if was and pct(covered, total) > pct(was.covered, was.total) then
  covered, total = was.covered, was.total
end
```

A regen never raises a row. Verified empirically during the #1192 review: I set
four `_perf/bench/*` rows to `0 1` and ran `bin/cosmic --make coverage
--baseline`; they stayed `0 1`. So once a bad floor lands, the only recovery is a
hand-edit by someone who knows the history — and the gate stays green the whole
time, silently under-protecting those files forever.

The two compound. Failure 1 lands a garbage floor; failure 2 means it can never
be regenerated away. PR #1195 carries four such rows today (`fs_bench` 75.2%
committed against 87.9% honest, and three more 6–13pp below honest).

## Proposed countermeasure

Core, per `enable.md`'s ordering. Two halves, both cheap, and a refiner should
confirm they belong in one slice:

- **Refuse rather than freeze.** `--baseline` declines to write when the `.cov`
  corpus it is about to read is materially smaller than the tree it claims to
  measure, and says what it wants instead ("ran 140 of 846 expected .cov files;
  run `--make test` first"). The `declined:` line at
  `_tool/coverage/baseline.tl:218-230` is the existing precedent for saying so
  without moving the verdict.
- **Give the valve a release.** (Both halves are settled by the owner
  decision below, which supersedes this section's either/or.)

## Owner decision, 2026-08-19 — refuse + honest regen

Confirmed by the goal owner: `--baseline` refuses to run on a corpus it
should not trust, and when it runs it writes the HONEST measurement in
both directions — a raise shows in the reviewable diff like any other
change. The one-way valve is deleted; the corpus guard and the diff
review replace it. ("Keep the valve with an opt-in raise flag" and
"refusal only" were considered and declined.)

## Change

Settled per the owner decision; measured 2026-08-19 at `f420391`.

`_tool/coverage/baseline.tl` (424 lines):

1. **Delete the never-raise rule.** `render`'s floor clamp (lines
   82–84: keep `was` when the fresh pct is higher) goes, and `text_for`
   (line ~338) stops threading `previous` into `render` for clamping —
   the fresh measurement is the row. `lowered()` (line 366) STAYS: it is
   the visibility half, and now narrates both directions — extend its
   `note` to emit raises too (`%s %.1f%% -> %.1f%%` reads either way),
   so the rewrite's stderr names every row that moved.
2. **The corpus guard — breadth, not magnitude.** Before writing, when
   a committed floor exists: count the rows the rewrite would LOWER
   (the `lowered()` machinery already computes this). When MORE THAN
   HALF of the floor's rows would drop, refuse:
   `coverage --baseline REFUSED: this run would lower N of M floor rows
   — that is a measurement problem, not a decision. Run
   'bin/cosmic --make test' first so every .cov is fresh; a genuine
   project-wide decline is accepted by deleting .cosmic-coverage and
   starting the floor again.` A majority-lowering rewrite was the
   observed failure (140 problems, 73.5% -> 14.9%, twice on 2026-08-17);
   a deliberate broad decline keeps the explicit, diff-visible escape
   the message names. No tolerance knobs, no magic percentage.
3. **Tests** (`_tool/coverage/baseline_test.tl`, 484 lines — the
   parser-test deletions in 3I1J9Xhg are what make room, another reason
   for the blocked_by below): a wrongly-low row raises back on regen
   and the raise is narrated; a partial corpus (floor of 4 rows, fresh
   data lowering 3) refuses with the count; a fresh run lowering 1 of 4
   writes and narrates it; no-floor first run still writes.

## Non-goals

- no change to the ratchet CHECK (`compare`, tolerances, verdicts) —
  gating and regenerating stay separate judgments.
- no provenance header, no format change (3I1J9Xhg owns format), no new
  flags — the refusal message's two remedies are the whole interface.
- `.gitattributes` `merge=union` untouched.

## Blocked by

3I1J9Xhg (same file: it replaces this file's parser with `_tool.floor`
and frees the test-file headroom) — mirrored in `blocked_by`.

## Acceptance

- `bin/cosmic --make test _tool/coverage/baseline_test.tl` ends
  `test: PASS (1 files)`.
- `git grep -n "never raise\|floor rule" _tool/coverage/baseline.tl`
  shows the clamp gone and the guard's doc in its place.
- `bin/cosmic --make ci` ends `ci: PASS` — the committed floor does not
  change bytes in this PR (the tree's corpus is complete in CI, and
  honest regen is not run as part of the diff).

## Enablement

none needed — the decision is recorded above with its rejected
alternatives; the guard reuses `lowered()` rather than new counting;
the file-headroom dependency is carried in `blocked_by`.

**3. A frozen zero row in the live floor, found in the field
(2026-08-25, main a0c4ebd).** The committed `.cosmic-coverage` carries
`cosmic/fetch/init.tl = 0/139` while the same tests measure the file
at 96.1% (146/152): `o/bin/cosmic --make coverage cosmic/fetch` then
`o/bin/cosmic --coverage-report o/.coverage cosmic/fetch` prints
`cosmic/fetch/init.tl 96.1% 146/152`. The fetch tests fully exercise
the module against forked loopback servers, so the row was frozen at
zero by some earlier partial run and the decline-only ratchet has
been decorative for this file ever since — the exact
can-never-raise-a-row-back failure this item names. A fix should
also sweep the floor for other zero rows that measure non-zero
today.
