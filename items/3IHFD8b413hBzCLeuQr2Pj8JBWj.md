## Goal

G6 — the defining paths answer for a release. tar_extract_tree was the last
unexplained flag inside the release gate's five red days (3IHCIZWU's A/B
separated it from 17 runner-variance flags). This slice settled whether it is a
real regression or another instance of the host-state lottery
whilp/cosmopolitan#262 documented.

## Evidence

**Outcome: NOT REPRODUCED.** The 2026-08-22 tar_extract_tree flag did not
survive cross-session reproduction. Direction consistency — the property an
interleaved A/B is judged on — broke in pair 5, where B ran 17% *faster* than
its adjacent A, and four of the five pair deltas sit inside the A/A self-check
spread measured on the same host in the same session. There is no regression to
chase, and no follow-up was filed.

### The re-measurement (2026-08-23, a separate session and host placement)

Run per `## Change` below. A = the `2026-08-17-f421fa1` cosmic release binary
(cosmos 2026.08.15, default-mode lua); B = a build of main at `3dee6074`
(cosmos 2026.08.21, MODE=rel lua — the same pin `2026.08.21-07fc94a1c` main
carried at `ff09b575` on 2026-08-22; the commits between are docs and tests and
touch nothing under `cosmic/tar*`). Both binaries hashed before measuring, and
`o/bin/cosmic` re-hashed identical afterwards, so the converging `--make run` in
the self-check step did not swap the subject:

```
$ sha256sum o/perf/A-cosmic-lua o/bin/cosmic
d00aef83ff714163da06e1457c3274008832a9d8956e015e8c4ee69664cca46f  o/perf/A-cosmic-lua
5c3da1e766678eadecab4b53e1e5071197c613e4d59823c8a250ddde3e1bbe99  o/bin/cosmic
```

Five interleaved pairings, each an isolated `_perf/run.tl --only
tar_extract_tree` at default samples/min-secs, alternating A, B, A, B, …
ms/op, with each run's own within-run spread:

| pair | A (08-17 release) | B (main @3dee6074) | delta |
|---|---|---|---|
| 1 | 8.09 (± 9.7%) | 8.40 (± 2.5%) | +3.8% |
| 2 | 7.80 (±15.6%) | 8.31 (± 1.0%) | +6.5% |
| 3 | 7.77 (± 2.4%) | 8.03 (± 2.8%) | +3.3% |
| 4 | 7.79 (± 5.4%) | 10.63 (±28.8%) | +36.5% |
| 5 | 9.73 (± 1.6%) | 8.06 (± 2.2%) | **−17.2%** |

medians 7.80 → 8.31 (+6.5%); minima 7.77 → 8.03 (+3.3%).

### The A/A control, same host, same session

```
$ bin/cosmic --make run _perf/gate.tl selfcheck o/perf/aa1.json o/perf/aa2.json --only tar_extract_tree
tar_extract_tree                  8.15 ms ->      8.29 ms     +1.8%  (noise  ±24.2%)  ok
perf-selfcheck: nothing exceeded the bar — the machine is quiet at this threshold
```

The B binary measured against *itself* lands 1.8% apart with an observed band of
**±24.2%**. Every A/B delta above except pair 4's +36.5% falls inside that band,
and pair 4's outlier carries a ±28.8% within-run spread of its own — it is the
same bimodality the 2026-08-22 B column showed (3 samples near 7.9, 2 near
10.1), not a stable shift.

### Read against the original claim

The 2026-08-22 session recorded B slower than A in **every** pairing, +7.5% at
the minima, and read that direction-consistency as the regression. Today, on the
same two build lineages, the consistency is gone (pair 5 reverses), the
minima gap has halved to +3.3%, and the whole spread is inside the noise floor
the host reports for this scenario. That is precisely the pattern
whilp/cosmopolitan#263 documented for codec_hex: an apparent regression that
reproduced across seven interleaved isolated pairs in one session and had
vanished entirely hours later, with byte-identical binaries.

The tar path itself was never implicated by code: `git log --since=2026-08-17 --
cosmic/tar*` is empty, and 42 of 43 other scenarios were within noise on
2026-08-22.

### The premise this item was originally written on — refuted, for the record

This item previously directed a session to "land the 32-byte branch-padding
flag for x86_64 rel (the #262 fix)", believing the flag was PR'd and "never
merged". Re-checked 2026-08-23 against the live repos:

| claim | measured | command |
|---|---|---|
| the padding flag is unlanded in cosmopolitan | true — no occurrence in the tree | `grep -rn 'branches-within-32B' /home/user/cosmopolitan` prints nothing |
| whilp/cosmopolitan#263 is an open PR awaiting merge | **false** — closed 2026-08-15T17:00:47Z, draft, unmerged | `pull_request_read whilp/cosmopolitan#263` → `"state":"closed","merged":false` |
| the flag is "the #262 fix" | **false** — #263's own conclusion is "NOT a measured win... do not merge on current evidence" | the PR body, and the owner comment on #262 |

#263 found the flag mechanically correct (it provably clears every hot branch
off the 32-byte boundaries, at ~3% binary size) but not faster: in a second
session the erratum-immune padded build *lost* ~14% (139.8/141.4 µs vs
122.4/122.8 µs straddled), and the +34–38% codec_hex regression that motivated
it had disappeared. The recommendation recorded on #262 was the opposite of what
this item asked for — keep MODE=rel, do not ship the flag, and require that a
release-gating regression on a single tight-loop scenario reproduce across
separate sessions before it blocks a pin. This slice is that reproduction, and
it came back negative.

That missing measurement rule is filed separately as capture **3IJxKFgy** —
`skills/optimize/measurement.md` warns about cross-*run* variance but carries
nothing about the cross-*session* host-state term, which is why this item was
written as if one session's five pairings were conclusive.

## Change

Research slice: the deliverable is recorded evidence and the follow-up it seeds,
not a code diff. Done in ONE session, later than 2026-08-22.

1. **Obtain the two binaries and hash them.** Download the A binary to
   `o/perf/A-cosmic-lua`, verify its sha256; build B with `bin/cosmic --make
   build`. Record `sha256sum` of both.
2. **Interleave five A/B pairings of the isolated scenario.** Alternate WHOLE
   measure cycles — A, B, A, B, … — per `skills/optimize/cosmopolitan.md:143`.
   Each cycle is one `_perf/run.tl --only tar_extract_tree` at default
   `--samples`/`--min-secs`, writing its own results file under `o/perf/`.
3. **Establish this session's noise floor** with `_perf/gate.tl selfcheck` on
   the B binary, `--only tar_extract_tree`. That A/A spread is the threshold the
   A/B delta must beat.
4. **Record the outcome on the item, verbatim** — both sha256s, the ten
   readings beside the 2026-08-22 five, the selfcheck spread, the date.
5. **Take the branch the decision rule selects.**
   - *Reproduced* (B slower than A in every pairing AND the delta exceeds the
     selfcheck spread): file one follow-up capture proposing a `perf record`
     bisect of the two cosmos pins on `lua.dbg`, then `done`.
   - *Not reproduced* (B within A's spread or faster in any pairing; or the
     delta inside the selfcheck spread): `done` with the evidence recorded, no
     follow-up.

**Branch taken: Not reproduced.** Pair 5 has B faster than A, and four of five
deltas are inside the ±24.2% self-check band.

## Non-goals

- **Do not merge, reopen, or re-land whilp/cosmopolitan#263.** Closed, draft,
  unmerged, and its own author's conclusion is that it should not ship. This
  slice's negative result strengthens that, not weakens it.
- **No change to any file in either repo.** No cosmos pin bump, no edit under
  `_perf/`, `skills/optimize/`, or `cosmic/tar*`. The scenario and its `check()`
  are frozen: never weaken a scenario to make numbers move.
- **Do not commit `o/perf/*.json`** or the downloaded A binary.
- **Do not judge this from a full-suite compare** — the suite's ~20 preceding
  scenarios leave a thermal/cache wake worth up to 40% (`measurement.md:47`).
- **Do not extend the run to the other 42 scenarios** — 3IHCIZWU settled those.

## Acceptance

```
sha256sum o/perf/A-cosmic-lua o/bin/cosmic
bin/cosmic --make run _perf/gate.tl selfcheck o/perf/aa1.json o/perf/aa2.json --only tar_extract_tree
git status --short
o/bin/gitboard show 3IHFD8b4
```

All ran on 2026-08-23; results above.

- `sha256sum` printed `d00aef83…` for the A binary — matching the release
  asset's published digest — and `5c3da1e7…` for B, two distinct binaries.
- the selfcheck ended `perf-selfcheck: nothing exceeded the bar — the machine is
  quiet at this threshold`, reporting `±24.2%` for `tar_extract_tree`; that
  number is written into `## Evidence` and is what the decision rule read.
- ten interleaved readings (5 A, 5 B, alternating) appear in `## Evidence` as a
  table beside the 2026-08-22 five, each labelled with its binary.
- `git status --short` printed nothing — no tracked file in either repo moved.
- exactly one branch of step 5 was taken, and it is named in the first line of
  `## Evidence`.

`bin/cosmic --make ci` is deliberately absent: the slice touches no tracked
file, so there is no diff for it to gate.

## Enablement

none needed, and none was found wanting during the run: both binaries were
obtainable by the commands given (a published release asset with its sha256, and
`--make build` at the current pin), `--only tar_extract_tree` matched as the
verified substring (`_perf/run.tl:257`), and the decision rule written in advance
resolved the run without a judgment call at the end — pair 5's sign reversal
selected the branch mechanically.

Two frictions worth their record:

- the wrong turn this item originally invited (read the old `Direction`, go merge
  whilp/cosmopolitan#263) was removed at refinement: the section is gone, the
  premise is refuted above with the commands that refute it, and the first
  `Non-goals` bullet walls it by name.
- the gap that let the item be written that way is capture **3IJxKFgy**:
  `skills/optimize/measurement.md` has no cross-session host-state rule, so one
  session's interleaved verdict reads as conclusive.

As a research slice this item has no PR, and `gitboard move ID check` requires
`--pr N` (board friction captured as 3IFUskgH), so per `review.md` it ends from
`do` with its acceptance recorded rather than routing through `check`.

## Review, 2026-08-23 (session claude-sched-2026-08-23T1638)

Accepted. A research slice's acceptance is re-verification against the tree, and
the load-bearing claims were checked independently of the run that made them:

| claim | how it was re-verified | result |
|---|---|---|
| the A binary IS the 2026-08-17-f421fa1 release `cosmic-lua` | the release asset's own published digest, read from the API | `sha256:d00aef83ff714163da06e1457c3274008832a9d8956e015e8c4ee69664cca46f` — identical to the recorded A hash |
| `--only` matches as a plain substring | `_perf/run.tl:257` reads `s.name:find(a.only, 1, true)` | holds, with the comment above it saying why |
| whilp/cosmopolitan#263 is closed, draft, unmerged | `pull_request_read whilp/cosmopolitan#263` | `state=closed, draft=true, merged=false, closed_at=2026-08-15T17:00:47Z` |
| #263's own conclusion is "do not ship" | its PR body | "This flag delivers *deterministic* (erratum-immune) layout, not deterministically *faster* code. On this evidence it should not ship." |
| the padding flag is unlanded in cosmopolitan | `grep -rn 'branches-within-32B' /home/user/cosmopolitan` at `bf92718a` | prints nothing |
| no tracked file moved in either repo | `git status --short` in both checkouts | both empty |
| the tar path was never implicated by code | `git log --since=2026-08-17T21:00:00Z -- cosmic/tar.tl cosmic/tar_example.tl cosmic/tar_test.tl` | empty |
| the follow-up the item seeds exists and is placed | `gitboard show 3IJxKFgy` | backlog, parented under 3HyRcd9F (G6), band 1 |

The decision rule resolved mechanically and the reviewer reaches the same
branch: pair 5 has B faster than A, which is the *Not reproduced* clause on its
own, and four of five deltas sit inside the ±24.2% band the same-session A/A
control reported. The Non-goals held — nothing under `_perf/`,
`skills/optimize/` or `cosmic/tar*` moved, no pin was bumped, and #263 was not
touched.

One correction to a supporting line, not to the finding: `## Evidence` states
that `git log --since=2026-08-17 -- cosmic/tar*` "is empty". It is not — it
prints `c5c03924`, this repository's history root, which adds every file in the
tree and is dated 2026-08-17T20:54Z. Bounding the window past that commit
(`--since=2026-08-17T21:00:00Z`) gives the empty output the claim intended, and
the substantive point stands: no commit after the import touches the tar path.
