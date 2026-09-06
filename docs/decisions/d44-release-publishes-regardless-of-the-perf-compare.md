# D44 — the release publishes regardless of the perf compare; perf is a daily non-blocking lane

- **date:** 2026-09
- **status:** active
- **context:** `release.yml`'s "compare against the previous release"
  step refused to publish a release whose `_perf` scenarios read slower
  than the previous release's binary, re-measured on the same runner.
  Three records bought that gate more evidence —
  [D31](d31-gate-noise-from-every-control-pair.md) reads noise from
  every control pair, [D34](d34-reproduction-against-remeasured-baseline.md)
  then [D36](d36-baseline-pair-third-reading-median.md) judge the
  baseline by a majority of readings, [D35](d35-dismissal-owes-evidence.md)
  makes a dismissal owe evidence — and each says in its own
  consequences that it lowers the false-red rate without eliminating
  it. The record of what the gate actually stopped: five consecutive
  scheduled releases 2026-08-18..22 held against a stored `perf.json`
  while an interleaved A/B showed 42 of 43 scenarios identical; three
  held 2026-08-24..26 on `json_decode_large`, exonerated by an A/B
  that varied only the cosmos pin; the 2026-09-03 run (`33746684991`)
  held on `re_match_log_line` at **+1.5%** inside a **±10%** band,
  counted as a regression because no same-binary control happened to
  swing that day. In the same period the gate caught one real
  regression (`codec_base64_roundtrip_64k`, +21%), worked upstream in
  cosmic-lua/cosmopolitan — a fix the held releases did not speed up.

  What a held release costs is not the day's binary. The trust root
  `bin/cosmic.pin` can only name a published release, so a red release
  lane freezes every change that stages behind a pin bump: on
  2026-09-04 the D43 seed pass, a curated `tl.Env`, and through them
  three cosmos pin bumps and their consumers, all waited on a release
  the perf gate would not cut. `skills/optimize/measurement.md` already
  states the standard for a regression on a fixed-overhead scenario —
  reproduction across separate sessions, days apart — and a gate that
  fires on one session's reading cannot meet it by construction.
- **decision:** the release is published whatever the perf compare
  reads, and the compare moves to its own scheduled lane:
  - `release.yml` measures no speed and branches on no perf verdict:
    no `_perf/run.tl`, no `_perf/gate.tl`, no `perf_gate` input.
    Releases stop carrying `perf.json`, `selfcheck.json` and
    `compare.txt`; the G9 size report and the G6 peer table stay
    release assets, and the release notes carry their two lines.
  - `perf.yml` runs daily at `0 3 * * *` — before `release.yml`'s
    `0 6`, so the baseline is yesterday's release and the subject is
    the tree today's release is cut from — and on `workflow_dispatch`.
    It builds the tree in two generations as the release does,
    measures it twice, fetches the latest published release's binary
    (`_perf/baseline.tl --asset cosmic-lua`), measures that through
    `_perf/baserun.tl`, and runs `_perf/gate.tl compare … --baseline-bin`
    unchanged. The compare's rules — D31's control pairs, D36's
    median, D35's dismissal bar, the 10% bar and `TRIAGE_K` — are not
    touched; only the caller moved.
  - the lane is non-blocking, not unfailing: nothing downstream reads
    it, no asset is withheld, and `perf-compare: FAIL` still fails the
    step and the job, because a red run on a reproduced regression is
    the only signal the lane has. Its readings are uploaded as run
    artifacts on every exit; that is where the perf history lives.
  - `_build/workflows_test.tl` ratchets both halves: the compare step
    in `perf.yml` keeps `pipefail`, `exit "$rc"`, the SKIP path and
    `_perf/baserun.tl`; `release.yml`'s `build` job carries none of
    the perf names.
- **rejected:**
  - **keep the gate and widen the bar, or excuse named scenarios.**
    D31's rejected list already: the change that makes the red go
    away takes the gate with it, and the +21% real regression must
    still fail. A wider bar keeps every cost of a gate and buys a
    slower one.
  - **keep the gate, default `perf_gate: false`.** A gate nobody
    enables is a report with a misleading name and a dispatch input
    to remember; the scheduled run, the one that publishes daily,
    would never enforce it anyway.
  - **trigger the compare from the release (`workflow_run`) and
    compare release against release.** Keeps the measurement on
    exactly the shipped binaries, at the price of a second-newest-
    release picker in `_perf/baseline.tl` and a measurement that
    lands after the artifact it would have informed. The before-
    release slot measures the same commit the release is about to
    cut, one instrument, no new tooling.
  - **more evidence in the gate — N isolated re-measures, a committed
    per-scenario noise profile.** Both are D31's deferred instruments
    and both stay available to the lane. Neither changes the fact the
    context states: one runner's one session cannot meet the
    cross-session standard, so whatever the gate reads, a release
    held on it is held on evidence the project itself calls
    insufficient.
- **consequences:** a real regression ships in that day's release and
  is read the next morning at 03:00 — the accepted cost, and the one to
  measure this record against: a shipped regression that costs more
  than the held releases did is what would make us revisit, and the
  before-release slot keeps the fix a same-day PR away. The perf
  history moves from release assets to `perf.yml`'s run artifacts,
  with the platform's retention rather than a release's; anyone
  wanting a longer record publishes the artifacts somewhere durable
  as a separate change. `_perf/skew_test.tl`'s guard now protects the
  perf lane rather than the release lane and is otherwise unchanged. G6
  in `docs/goals.md` reads "reported daily" where it read "enforced
  per release"; its win condition — no regression, trending down —
  is unchanged, judged from the lane's history instead of by refusal.
  A red `perf.yml` is a lane the board's `sync` does not yet observe
  (`_work/lanes.tl` lists three); adding it is a board-tool change.
