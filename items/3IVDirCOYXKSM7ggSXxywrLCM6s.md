## Goal

G6 — the defining paths, ratcheted. This item opened as a question:
the perf gate's sensitivity is level-dependent, so **is there a bar —
level-normalised, or µs-denominated — that reads the same at both
levels where today's fixed percentage does not?**

**Refined 2026-08-27: the question is ANSWERED, and the answer is no.**
Both candidate normalisations are refuted by figures already on the
board, so this item is no longer a gate change. What remains is to
RECORD the refutation where the next session looking at a swinging
codec row will read it, so the question is not re-opened a fourth
time. That record is the whole scope.

## Evidence

The same code delta — cosmos `2026.08.21-07fc94a1c` → `2026.08.24-
354c17e08`, arms verified byte-identical across both sessions
(`d8492168eace…` and `940f21bb25c2…`, `sha256sum`-checked in 3ISlWFiS,
in 3ITOUv0w, and a third time in 3ITHROpY) — was measured interleaved
inside ONE session, twice, at two different absolute levels. Both
verdicts REPRODUCED. From the medians those two items record:

| session | fast arm | slow arm | Δ µs | Δ % |
|---|---|---|---|---|
| 3ISlWFiS, ~191 level | 191.31 | 209.35 | **+18.04** | **+9.44%** |
| 3ITOUv0w, ~144 level | 144.29 | 173.38 | **+29.09** | **+20.16%** |

Medians and the two percentages are quoted verbatim from those items'
`## Result` sections (`med X → med Y µs (+P%)`); **neither item writes
the subtraction, so the µs column is computed here** — one subtraction
over endpoints both items state.

**That table refutes both candidate bars at once.**

- **Percentage is not invariant**: 9.44% → 20.16%, a factor of 2.14.
  This is the founded premise the item opened with, restated.
- **Absolute µs is not invariant either**: 18.04 → 29.09 µs, a factor
  of 1.61. So "normalise the delta by the session's own level", or
  equivalently "express the bar in µs", does not close the gap — it
  narrows it from 2.14x to 1.61x and leaves a bar that still means two
  different things in two sessions.
- **And the residual runs the WRONG WAY.** A level-normalised bar is
  motivated by the intuition that a code change adds roughly constant
  WORK, which reads as a larger percentage when the baseline is fast.
  The data says the absolute cost is *larger* at the *faster* level —
  29.09 µs at ~144 against 18.04 µs at ~191 — so the effect is neither
  additive nor multiplicative in the session level, and no
  single-parameter normalisation in either unit can be fitted to two
  points that move in opposite directions.

3IU0GxoA records the same asymmetry independently, from the level side
rather than the delta side: between the two sessions the byte-identical
BASE arm stepped ×1.326 while the byte-identical REGRESSED arm stepped
×1.207, and the item states that "the two ratios differ … so whatever
moves the level is not a uniform frequency scaling."

**What the tree already teaches, and what it does not.**
`skills/optimize/measurement.md` already carries the cross-session
effect and the remedy (`- **the term interleaving inside one session
cannot remove: host placement.**`, with its `codec_hex` morning/
afternoon table and the rule that a release-gating regression on a
tight-loop scenario needs reproduction across SEPARATE SESSIONS). What
it does NOT carry is this item's consequence: that a regression
correctly reproduced inside one session still has a MAGNITUDE that is
a property of the session, and that no change of units repairs it.
Measured:

```
grep -n -i 'magnitude\|normalis\|normaliz\|µs bar' skills/optimize/measurement.md
```

→ no matches, on `54aa87df`.

## Change

One bullet added to `skills/optimize/measurement.md`, immediately
after the existing `- **the term interleaving inside one session
cannot remove: host placement.**` bullet (which ends at the line
`first one would have cost a pin.`), since it is that bullet's direct
consequence and reads as a continuation of it.

The bullet says, in the chapter's own voice and its own bullet style:

- a regression reproduced inside one session is REAL, but its measured
  MAGNITUDE is a property of the session, not of the code;
- the two-row table above, with both units, and the identification of
  the arms as byte-identical across the two sessions;
- that **neither a percentage bar nor a µs bar normalises this**, with
  the two factors (2.14x and 1.61x) and the direction that rules out a
  fit;
- therefore: **quote a codec delta with the absolute level it was
  measured at**, and never compare a percentage from one session
  against a percentage from another — the number to carry forward is
  the pair of medians, not the percent;
- and the pointer that this was tested rather than assumed: board
  items 3ISlWFiS, 3ITOUv0w and 3IU0GxoA carry the readings and hashes.

Write it to the house standard (`skills/docs-style/SKILL.md`): what
the reader needs, in language that stands alone — no history of this
item, no "we investigated", no board-item narration beyond the one
evidence pointer above.

## Non-goals

- **No threshold, bar, floor, or gate change of any kind.** The answer
  to the question this item asked is "no such bar exists", so building
  one is the outcome this item exists to prevent. In particular no
  widening of `codec_base64_roundtrip_64k`'s noise floor: 3IU0GxoA's
  "What this does NOT license" paragraph is explicit that its evidence
  makes the scenario look MORE stable within a session, and 3ISlY5Xl
  held a release at +21.0% via `21.0 > max(10.0, 2 x 4.8)` measured in
  the SAME job on the SAME runner — the interleaved shape the
  cross-session effect cannot reach.
- **No history store.** The `_perf` machinery persists no A/A history
  and this item does not add one; that shape was dropped from 3IUBNQZZ
  for the same reason and nothing here revives it.
- **No decision record, and no D31 amendment.** Nothing D31 decided
  stopped being true — its triage arithmetic is untouched — and a
  candidate improvement that was tested and failed is evidence, not a
  reversal. `skills/decide/SKILL.md`'s amend rule is for a fact under a
  standing decision moving; none did.
- No `_perf` source change, no scenario change, no `check()` change.
- No edit to the host-placement bullet the new one follows: it stands
  as written.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The bullet exists and sits where the Change says:
  `grep -n 'magnitude' skills/optimize/measurement.md` names a line
  inside the new bullet, and that line number is greater than the line
  `grep -n 'first one would have cost a pin' skills/optimize/measurement.md`
  reports and less than the line
  `grep -n 'perf-compare. triages this for you' skills/optimize/measurement.md`
  reports — i.e. it landed between the host-placement bullet and the
  triage bullet, not at the end of the file.
- Both units and both factors are present:
  `grep -c '18.04\|29.09\|2.14\|1.61' skills/optimize/measurement.md`
  → at least `4`.
- **Nothing but that file changed.**
  `git diff origin/main --name-only` → exactly
  `skills/optimize/measurement.md`.
- **No threshold moved**, checked rather than assumed:
  `git diff origin/main -- _perf` is empty.
- The file stays under the cap: `wc -l skills/optimize/measurement.md`
  → under 500 (it is 134 on `54aa87df`).

## Enablement

None needed, and this is measured rather than asserted: the slice
touches ONE markdown file, so the `_perf/skew_test.tl` shadowing that
bounced 3IUBNQZZ (captured as 3IVF3HbV) cannot reach it — that guard
type-checks `_perf/**` sources and this diff has none. Every figure the
bullet carries is transcribed from 3ISlWFiS, 3ITOUv0w and 3IU0GxoA
above, with the one computed column marked as computed; no measurement
run is required to write it. Read 3IU0GxoA's "What this does NOT
license" paragraph before writing, so the bullet's last clause does not
drift into licensing a wider bar.

## Review — 2026-08-27 15:0x UTC, ACCEPT (session 0b13d2b4)

PR #1460 at head `5ee67919`, one commit, one file, +32/-0.

**The acceptance was re-run, not read.** In a scratch worktree
detached at `5ee67919`: `bin/cosmic --make fetch` → `fetch: PASS (2
pins)`, `--make build` → `build: PASS (547 files, 1 binary)`, `--make
ci` → `fmt: PASS (549 files)`, `check: PASS (549 files)`, `example:
PASS (35 files)`, `lint: PASS (649 files)`, `coverage: PASS (251
files)`, **`ci: PASS (5 stages)`** (251 checks: 250 passed, 1 skipped;
929 tests: 929 passed). The narrow checks reproduce the builder's
numbers exactly: `magnitude` at line 51, `first one would have cost a
pin` at 49, the triage bullet at 82 (49 < 51 < 82); `grep -c` for the
figures → 6 ≥ 4; `wc -l` → 166 < 500; `git diff origin/main
--name-only` → `skills/optimize/measurement.md` alone; `git diff
origin/main -- _perf` → 0 bytes. CI on that head is green on all five
lanes (run 33084481616: ci, build, repro, smoke macOS, smoke Windows).

**The arithmetic was recomputed from the sources, not taken from the
spec.** 3ISlWFiS's `## Result` states `med 191.31 → 209.35 µs
(+9.44%)` and 3ITOUv0w's states `med 144.29 → 173.38 µs (+20.16%)`;
the medians are the ones 3IU0GxoA's per-arm table records for the
byte-identical arms `d8492168…` and `940f21bb…`. 209.35 − 191.31 =
18.04 and 173.38 − 144.29 = 29.09, so 20.16 / 9.44 = 2.136 → 2.14 and
29.09 / 18.04 = 1.613 → 1.61. Every figure in the bullet is correct to
the digits it prints. (Recomputing the first percentage from the
printed medians gives 9.43%, not 9.44% — the source item's own figure
comes off unrounded medians; carrying 9.43 leaves the factor at 2.14
either way.)

**The statistics the prose asserts are true.** An additive model
predicts an equal µs delta and a larger percentage at the faster
level; a multiplicative model predicts an equal percentage. The rows
violate both, and in the direction the bullet names: the absolute cost
is LARGER at the FASTER level (29.09 µs at ~144 against 18.04 µs at
~191), which is the opposite of what motivates a level-normalised bar.
"Narrows the gap without closing it" is right: 1.61 < 2.14. The
closing "there is no level-normalised bar to reach for" is one shade
stronger than the spec's "no single-parameter normalisation … can be
fitted", since two points admit a two-parameter fit — but that fit
would be unfalsifiable, the two named models are the ones a reader
would reach for, and the operative instruction (quote the level, carry
the medians) is exactly right. Not a finding.

**Diff is the Change, walls held.** All five components the `##
Change` enumerates are present and nothing else is: the magnitude
claim, the two-row table in both units with the arms named
byte-identical, the two factors with the direction, the working rule,
and the one evidence pointer. `git diff … -- _perf` is 0 bytes,
`docs/decisions/` is untouched, and the host-placement bullet above is
byte-identical — the insert begins after its last line. No threshold,
no floor, no history store, no `check()`.

**Finding 1 — the Acceptance command is the two-dot form, and this is
a recurrence. Confirmed; not blocking.** The spec's `git diff
origin/main --name-only` and `git diff origin/main -- _perf` diff
against main's TIP, not the merge base. Demonstrated on a worktree
holding this PR's commit two behind `origin/main`: two-dot named 114
files and 32,740 bytes under `_perf`; `git diff origin/main...HEAD`
named exactly `skills/optimize/measurement.md` and 0 bytes. The
`_perf` bullet is the worse of the two — the check whose whole job is
to prove the "no threshold moved" wall held would read another
branch's landed test migration as a violation. It does not block
because the builder ran it on a current checkout, where the two forms
agree, and this review reproduced that result independently; the
defect is in the spec's wording, not the implementation. 3IU0GxoA's
`## Review 3` recorded exactly this as a ready-bar note one refinement
pass earlier, and 3IOXhlWb's spec had already written the rule out in
full before that, so prose has now failed to carry it twice. Filed as
**3IVHIoAx** — a pure check in `_work/spec.tl` that refuses the
two-dot form inside an `Acceptance` section (75 such invocations across
57 item specs today, against 23 correct three-dot ones).

**Finding 2 — no decision record was owed. The builder's call is
correct.** `skills/decide/SKILL.md`'s three tests: the second fails
outright — there is no losing option a competent contributor would
have chosen, because the µs-denominated bar was not traded away, it
was REFUTED by measurement, and "no loser, no record — that is a
design note, not a decision". The skill's exclusion list names this
case twice over: "do not open a record for … a performance hypothesis
(a `perf` issue — `skills/optimize`)" and "a rule a comment can carry
in place". D31 needs no amendment either: its live parts — `TRIAGE_K =
2`, the 10% bar, `triage_many` over every same-binary control pair —
are untouched, and its mechanism is a same-JOB A/A control, which is
level-invariant by construction, so this item's finding explains why
D31's shape is the right one rather than moving a fact under it. The
one place the two could meet later is D31's parked "committed
per-scenario noise profile"; if that is ever proposed, this bullet is
the evidence to read first, and it lives where that reader will be.

**A correction to this item's own Non-goals, for the record.** "The
`_perf` machinery persists no A/A history" is half wrong.
`release.yml:126-132` runs the full suite twice against the same
binary in the same job (`perf.json`, then `selfcheck.json`), which is
a genuine full-suite A/A control pair; only `perf.json` survives as a
release asset. The Non-goal itself held — the diff adds no history
store — and no false statement reached the tree, since the shipped
bullet makes no claim about persisted history. Captured as 3IVGNOMt.

**Serves the Goal, and is the least thing.** G6's win condition is
served by the refutation being readable where a swinging codec row is
worked; 32 lines is what the five required components cost, with no
helper, no restructure and no second claim.

**Verdict: ACCEPT.**
