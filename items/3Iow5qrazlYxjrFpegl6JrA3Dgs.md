## Evidence

Measured 2026-09-03 from the Actions API and the job log.

    GET /repos/cosmic-lua/cosmic/actions/workflows/release.yml/runs?per_page=3
      33746684991  2026-09-03T10:53:05Z  failure   (head_sha 63cc3a60, event schedule)
      33621832055  2026-09-02T10:54:03Z  success
      33501918861  2026-09-01T11:19:45Z  success

Job `build` (id 100620662371) fails at step `compare against the
previous release`; every earlier step is green. The log tail:

    perf-compare: re_match_log_line flagged in pass 1 and read quiet on the retry,
      but no same-binary control explains the gap -- counted as a regression
    re_match_log_line   3.35 µs -> 3.40 µs  +1.5%  (noise ±10.0%)  regression
    49 scenarios: 1 regression, 1 faster, 46 ok, 1 noise, …
    perf-compare: FAIL
    perf-baseline: OK 2026-09-02-c60dcf1
    perf gate: this release regressed against the previous one and was not published.
      re-run the release workflow to re-measure: a real regression reproduces, noise does not.
      to publish past a KNOWN, captured regression, dispatch this workflow once with perf_gate: false.

`63cc3a60` is exactly the head `c5wU_p1n9` measured
(`re_match_log_line` on 63cc3a60 vs baseline c60dcf19, isolated to
`cf416d85`, #1646's runtime `assert` in `cosmic/re.tl`'s `match()`).
This lane is that item's symptom: two pullable items, one root
cause, both touching `cosmic/re.tl` — hence the block. The workflow
also re-runs itself daily (`0 6 * * *`) and accepts
`workflow_dispatch` with `prerelease` (default true) and `perf_gate`
(default true) inputs (`release.yml:8-18`).

## Change

After `c5wU_p1n9` is done, and only then:

1. Dispatch the workflow on `main` with defaults
   (`gh workflow run release.yml`), or wait for the next 06:00 UTC
   cron; record the run id on this item.
2. Read the outcome of `compare against the previous release`:
   - green → this item is `completed`; note the release tag it
     published (the `pin-bump-1650` item wants it).
   - red on `re_match_log_line` again with `c5wU_p1n9`'s fix merged →
     that is a new finding: file it under `c5wU_p1n9`'s parent with
     this run's log lines, block this item on it, release the claim.
   - red on a different scenario → a new item with the scenario's
     compare line and the tie-break message; same block-and-release.
3. `perf_gate: false` is used ONLY when `c5wU_p1n9` ended by
   explicitly accepting the cost and moving the scenario baseline —
   then one dispatch with it, the run id and the reason recorded here.

No file in the tree changes under this item.

## Non-goals

Not touching `.github/workflows/release.yml` and not the gate's
retry/tie-break design (D34, D35, D36 — `gXW8_KTLC`, `mSpj_1nXz`).
