## Goal

G6 — the defining paths answer for a release. tar_extract_tree is the last
unexplained flag inside the release gate's five red days (3IHCIZWU's A/B
separated it from 17 runner-variance flags). Settle whether it is a real
regression or another instance of the host-state lottery whilp/cosmopolitan#262
documented, so the release gate stops carrying an open red it cannot act on.

## Evidence

**The 2026-08-22 measurement (this item's original evidence).** Interleaved
A/B, one machine, one session: A = the `2026-08-17-f421fa1` cosmic release
(cosmos 2026.08.15, default-mode lua), B = main at `ff09b575` (cosmos
2026.08.21, MODE=rel lua). tar_extract_tree, 5 alternating pairings:

    A: 7.62 7.55 7.29 7.44 7.32 ms   (tight, spread 0.33)
    B: 10.04 7.84 7.91 10.17 8.09 ms (bimodal: 3 near 7.9, 2 near 10.1)

B is slower than A in every pairing; +7.5% comparing the two minima (7.29 →
7.84). 42 of 43 other scenarios were within noise, and `git log
--since=2026-08-17 -- cosmic/tar*` is empty, so no cosmic-layer change is
implicated. The moving parts are the two cosmos pin bumps (be9b1faf, aaf4af95);
the 2026-08-21 cosmos releases are the first cosmic has pinned that ship lua as
MODE=rel (whilp/cosmopolitan#261).

**The premise this item was written on is refuted — read this before acting.**
This item previously directed a session to "land the 32-byte branch-padding
flag for x86_64 rel (the #262 fix)", on the belief that the flag was PR'd and
"never merged". Re-checked 2026-08-23 against the live repos:

| claim | measured today | command |
|---|---|---|
| the padding flag is unlanded in cosmopolitan | true — no occurrence in the tree | `grep -rn 'branches-within-32B' /home/user/cosmopolitan` prints nothing |
| whilp/cosmopolitan#263 is an open PR awaiting merge | **false** — closed 2026-08-15T17:00:47Z, draft, unmerged | `mcp github pull_request_read whilp/cosmopolitan#263` → `"state":"closed","merged":false` |
| the flag is "the #262 fix" | **false** — #263's own conclusion is "NOT a measured win — hold as a documented experiment, do not merge on current evidence" | the PR body, and the owner comment on #262 |

#263 measured the flag and found it mechanically correct (it provably clears
every hot branch off the 32-byte boundaries, at ~3% binary size) but **not
faster**: in a second session hours later, with byte-identical binaries and the
same reported CPU, the erratum-immune padded build *lost* ~14% (139.8/141.4 µs
vs 122.4/122.8 µs for the straddled rel build), and the original +34–38%
codec_hex regression that motivated the flag had vanished entirely. A single
unchanged binary swung −38% between sessions.

The recorded recommendation from that work, on #262, is therefore the opposite
of what this item asked for: keep MODE=rel, do not ship the flag, and instead
require that **a release-gating regression on a single tight-loop scenario
reproduce across separate sessions / host placements before it blocks a pin.**

The 2026-08-22 evidence above is exactly the shape that standard refuses to
accept on its own: one session, one host placement, and a B distribution whose
bimodality (3 samples near 7.9, 2 near 10.1) is the signature of the host-state
term rather than of a uniform algorithmic cost. So the question this item exists
to answer is still open, and the way to close it is a second session — not a
build flag.

**The measurement environment is available.** The A binary is a published
release asset: `cosmic-lua` at `2026-08-17-f421fa1`,
`sha256:d00aef83ff714163da06e1457c3274008832a9d8956e015e8c4ee69664cca46f`
(`mcp github get_release_by_tag whilp/cosmic 2026-08-17-f421fa1`). The B side
builds from the tree at the current pin, `version = "2026.08.21-07fc94a1c"`
(`cat 3p/cosmos/cosmos_pin.tl`). The scenario is `tar_extract_tree`, defined at
`_perf/bench/tar_bench.tl:115` (`grep -rn tar_extract_tree _perf/`), and
`_perf/run.tl` takes `--only SUB` as a literal substring match
(`_perf/run.tl:257`, `s.name:find(a.only, 1, true)`).

## Change

This is a research slice: the deliverable is recorded evidence and the
follow-up it seeds, not a code diff. Do all of it in ONE session, and that
session must not be the 2026-08-22 one (any later scheduled run satisfies this;
record the date you ran on).

**1. Obtain the two binaries and hash them.** Download the A binary to
`o/perf/A-cosmic-lua` and verify it against the sha256 above; build the B
binary from the tree with `bin/cosmic --make build`, giving `o/bin/cosmic`.
Record `sha256sum` of both — measurement.md's "know which binary you measured"
rule, and the compare gate refuses a compare whose two sides hashed the same
binary.

**2. Interleave five A/B pairings of the isolated scenario.** Alternate WHOLE
measure cycles — A, B, A, B, … — never all of A then all of B, per
`skills/optimize/cosmopolitan.md`'s interleave section (`:143`). Each cycle is
one `_perf/run.tl --only tar_extract_tree` invocation at the default
`--samples`/`--min-secs` (measurement.md `:64`: lower values are for scouting,
not for accept/reject decisions), writing to its own results file under
`o/perf/`. Nothing else heavy runs on the machine during the run.

**3. Establish this session's noise floor for the scenario.** Run
`_perf/gate.tl selfcheck` on the B binary, narrowed with `--only
tar_extract_tree`. This is the A/A control: it says how far this scenario swings
against *itself* on this host today, which is the number the A/B delta has to
beat to mean anything.

**4. Record the outcome on the item, verbatim.** Rewrite this spec's
`## Evidence` to carry: the two sha256s, the ten interleaved readings as a table
alongside the 2026-08-22 readings, the selfcheck spread, and the date. Then
apply the decision rule in `## Acceptance` and take the branch it names. Commit
with `gitboard spec 3IHFD8b4 FILE`.

**5. Take the branch the rule selects.**

- **Reproduced** (B slower than A in every pairing AND the A-vs-B delta exceeds
  the selfcheck spread): the regression has now cleared #262's cross-session
  bar and is real. File ONE follow-up capture (`gitboard new`, unparented, with
  the two sessions' tables as `--spec-file` evidence) proposing the next step
  from `skills/optimize/cosmopolitan.md`: bisect the two cosmos pins (be9b1faf,
  aaf4af95) with `perf record` on `lua.dbg`, which localizes the cost to a
  function instead of re-litigating the build mode. Then `gitboard done
  3IHFD8b4`.
- **Not reproduced** (B is within A's spread, or faster, in any pairing; or the
  delta is inside the selfcheck spread): the 2026-08-22 flag was the host-state
  term, exactly as #262 predicted. `gitboard done 3IHFD8b4` with the evidence
  recorded. No follow-up capture — the finding is that there is nothing to chase.

## Non-goals

- **Do not merge, reopen, or re-land whilp/cosmopolitan#263.** It is closed,
  draft, unmerged, and its own author's conclusion is "on this evidence it
  should not ship". Nothing in this slice changes that evidence; if step 5
  reproduces, the follow-up is a bisect, not a build flag. Merging a draft the
  repo owner recommended against is the one wrong turn this item previously
  invited.
- **No change to any file in either repo.** No commit to `whilp/cosmopolitan`,
  no cosmos pin bump, no edit under `_perf/`, `skills/optimize/`, or
  `cosmic/tar*`. The scenario and its `check()` are frozen: never weaken a
  scenario to make numbers move (AGENTS.md, Performance).
- **Do not commit `o/perf/*.json`** or the downloaded A binary. `o/` is build
  output; AGENTS.md says never commit perf results.
- **Do not judge this from a full-suite compare.** The suite's ~20 preceding
  scenarios leave a thermal/cache wake that can shift a reading 40%
  (measurement.md `:47`); this scenario is judged in isolation, with `--only`,
  or not at all.
- **Do not extend the run to the other 42 scenarios.** 3IHCIZWU already
  separated them as runner variance; re-opening them is separate work.

## Acceptance

Run from the repo root. `<date>` is the day the session runs; it must be later
than 2026-08-22.

```
sha256sum o/perf/A-cosmic-lua o/bin/cosmic
bin/cosmic --make run _perf/gate.tl selfcheck o/perf/aa1.json o/perf/aa2.json --only tar_extract_tree
git status --short
o/bin/gitboard show 3IHFD8b4
```

- `sha256sum o/perf/A-cosmic-lua` prints
  `d00aef83ff714163da06e1457c3274008832a9d8956e015e8c4ee69664cca46f`, and
  `o/bin/cosmic`'s hash differs from it — two distinct binaries were measured.
- the selfcheck run ends on its own verdict line and its reported spread for
  `tar_extract_tree` is written into the spec; it is the threshold the decision
  rule reads.
- ten interleaved readings (5 A, 5 B, alternating) appear in the spec's
  `## Evidence` as a table, beside the 2026-08-22 five, each labelled with which
  binary produced it.
- `git status --short` prints nothing — this slice changes no tracked file in
  either repo.
- `o/bin/gitboard show 3IHFD8b4` prints the rewritten spec and ends
  `gitboard-show: 3IHFD8b4 is done`, and its trail carries a `spec` commit dated
  `<date>`.
- exactly one of the two branches in `## Change` step 5 was taken, and which one
  is stated in one sentence at the top of the rewritten `## Evidence`.

`bin/cosmic --make ci` is not in this list on purpose: the slice touches no
tracked file, so there is no diff for it to gate. Run it only if step 1's build
surprises you.

## Enablement

none needed. The two binaries are both obtainable by a command given above (a
published release asset with its sha256, and `--make build` at the current pin),
the scenario's `--only` substring is verified against the source line that
matches it (`_perf/run.tl:257`), the interleave protocol and the isolation
requirement are cited to the chapters that state them
(`skills/optimize/cosmopolitan.md:143`, `measurement.md:47`, `:64`), and the
decision rule is written in advance with both branches spelled out, so the
outcome of the measurement cannot become a judgment call at the end.

The one wrong turn a literal session could take — reading the old `## Direction`
and going to merge whilp/cosmopolitan#263 — is removed: that section is gone,
its premise is refuted in `## Evidence` with the commands that refute it, and
the first `Non-goals` bullet walls it by name.

The friction this slice will hit: it is a research slice with no PR, and
`gitboard move ID check` requires `--pr N`. That is board machinery friction
already captured as 3IFUskgH; per `review.md`, a research slice's accept is the
reviewer re-running the acceptance checks and `done`, with no move into `land`,
so this slice ends from `do` rather than routing through `check`.
