# D31 — the perf gate reads noise from every same-binary pair it already measured

- **date:** 2026-08
- **status:** active
- **context:** `release.yml`'s perf gate refuses to publish a release
  whose scenarios regressed against the previous one, and it separates a
  real regression from machine variance with an A/A self-check: run the
  current binary against itself, and let a scenario's own instability
  buy it credit against its flagged delta
  (`_perf/compare.tl`'s `triage`, `|regression| <= max(bar, TRIAGE_K *
  |control|)`, `TRIAGE_K = 2`). The separation is sound; the SAMPLE it
  rests on was not. `_perf/gate.tl`'s `gate_inner` measures the current
  binary up to three times — the caller's `current`, a `retry` after the
  first flag, and the self-check — and then triaged against exactly one
  pair of them, `retry` against the self-check, discarding `current` as
  a control. One pair is one sample of a quantity whose whole
  definition is that it varies. A scenario quiet in that pair and noisy
  an hour later gets no credit and holds the release. That is not
  hypothetical: `json_decode_large` read **+11.6%** against the previous
  release on 2026-08-24, and the same binary measured against itself in
  suite context drifts **+12.6%** on the same scenario — a swing that
  would have cleared the flag had the lane's one self-check pass
  happened to catch it. Three daily releases were held in a row, and an
  A/B holding cosmic fixed and varying only the cosmos pin exonerated
  the scenario outright: the newer pin is if anything faster.
- **decision:** a scenario's noise credit is the LARGEST swing it showed
  across EVERY pair of same-binary control runs the gate has already
  measured, not the swing in one designated pair. `compare.triage_many`
  takes the controls as a list, compares each unordered pair, and keeps
  per scenario the loudest delta among the pairs where that scenario
  cleared the bar; `compare.triage` becomes that function over one pair,
  so every existing caller is unchanged. `gate_inner` passes all three
  runs it holds, admitting `current` to the control set only when it
  names the same binary as the retry — a mismatch drops it from the set
  rather than refusing, leaving exactly the single pair the gate read
  before. Fewer than two controls is no pair and no reclassification.
  `TRIAGE_K` stays 2 and the default 10% bar stays 10%: the fix is more
  samples of the noise, never a wider tolerance for it.
- **rejected:**
  - **raise `--threshold`, or add the flagged scenarios to a
    noise-excused set** — the move that makes the red go away and takes
    the gate with it. The same release run that flagged
    `json_decode_large` as variance flagged
    `codec_base64_roundtrip_64k` at **+21.0%**, which the same A/B
    showed is a REAL, reproducible regression. Any change that excuses
    the first must still fail on the second, and a wider bar or a
    per-name exemption fails that test by construction.
  - **a committed per-scenario noise profile**, measured and ratcheted
    the way the coverage floor is, so each scenario is judged against
    its own demonstrated variance instead of one global bar. This is
    the better instrument and it is not rejected forever — it is
    rejected as premature here. It is a fourth committed floor under
    [D27](d27-one-committed-floor.md), with a regeneration command, a
    staleness gate and a merge story to own, bought to fix a hole that
    three free samples close. Taking it later costs nothing this
    decision spends.
  - **re-measuring a flagged scenario in isolation N times per side**,
    promoting `skills/optimize/measurement.md`'s tie-breaker into the
    gate. Correct, and strictly more evidence than this decision buys —
    at the cost of N extra measured runs inside a release job that
    already carries a 15-minute timeout on this step. The three runs
    this decision reads are already paid for.
- **consequences:** the gate samples three control pairs where it
  sampled one, at no runtime cost, so a scenario that misbehaves in any
  of them is credited for it. Stated plainly, because the failure this
  record exists to prevent is someone later reading it as a guarantee:
  this LOWERS the false-red rate, it does not eliminate it. A scenario
  quiet across all three pairs and noisy an hour later still reads as a
  regression, and the remedy for that is still what `release.yml`'s
  failure message says — re-run the workflow, because a real regression
  reproduces and noise does not. The asymmetry is the property to hold
  onto and the one the tests pin: `json_decode_large`'s numbers
  reclassify to noise, `codec_base64_roundtrip_64k`'s +21% stays a
  regression and keeps refusing the release, which is correct — that
  one is real and is worked where it lives, in whilp/cosmopolitan.
  `compare.triage`'s signature is frozen by its nine callers and stays;
  `triage_many` is the shape new callers take.
