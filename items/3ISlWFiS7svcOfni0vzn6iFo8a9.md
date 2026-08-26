## Goal

G6 — the defining paths, ratcheted (`docs/goals.md:123-140`), whose
measured half its own prose names as "the existing `perf-compare`
gate". `codec_base64_roundtrip_64k` is the one scenario still holding
that gate red, and until its status is settled honestly the release
lane cannot publish and `3ISVlHT6`'s pin bump has no release to point
at. This slice is RESEARCH: it produces recorded evidence and the
follow-up it implies, not a code change and not a PR.

(This item is parented under G3 — an honest type layer. That
mis-parenting is real, is captured as `3IT8rb3B`, and is not this
slice's to fix.)

## Evidence

All facts below measured 2026-08-26 with the commands beside them.

**The accused pin is no longer the shipping pin, and that is new.**
The prior A/B (`3ISWHyP7`, spec below under "what was measured
before") compared `2026.08.21-07fc94a1c` against
`2026.08.24-354c17e08`. The cosmos pin has moved TWICE since
(`git log --format='%h %ci %s' -- 3p/cosmos/cosmos_pin.tl`, then
`git show <sha>:3p/cosmos/cosmos_pin.tl | grep version`):

| cosmic commit | date | cosmos pin it set |
|---|---|---|
| `5ef13f40` | 2026-08-24 14:41 -0700 | `2026.08.21-07fc94a1c` |
| `ea71d799` | 2026-08-24 15:43 -0700 | `2026.08.24-354c17e08` |
| `bfe422e9` | 2026-08-25 23:42 -0700 | `2026.08.26-1e1658153` |
| `c3e57730` | 2026-08-26 05:46 -0700 | `2026.08.26-fe7c36c4c` |

`origin/main` today is `ef963bab` and pins `2026.08.26-fe7c36c4c`
(`grep version 3p/cosmos/cosmos_pin.tl`).

**What the release gate actually compares.** The newest published
release is `2026-08-23-d71d7f1`, and `git show
d71d7f15:3p/cosmos/cosmos_pin.tl | grep version` →
`2026.08.21-07fc94a1c`. So the lane's baseline arm runs on
`07fc94a1c` and its current arm runs on `fe7c36c4c` — a pin pair
NOBODY has A/B'd. `354c17e08` is an intermediate that never shipped
and is no longer on main.

**What was measured before** (`3ISWHyP7`, 2026-08-26, this container
class, four cores). Cosmic tree held at `5ef13f40`, only
`3p/cosmos/cosmos_pin.tl` varied, six alternating isolated rounds of
`o/bin/cosmic --make run _perf/run.tl --only
codec_base64_roundtrip_64k`:

| round | pin | µs/op | ± |
|---|---|---|---|
| 1 | 07fc94a1c | 191.73 | 14.2% |
| 2 | 354c17e08 | 227.05 | 9.8% |
| 3 | 07fc94a1c | 196.18 | 13.1% |
| 4 | 354c17e08 | 206.34 | 7.0% |
| 5 | 07fc94a1c | 193.46 | 4.8% |
| 6 | 354c17e08 | 208.58 | 3.3% |

Medians 193.46 → 208.58 µs, **+7.8%**, ranges non-overlapping.

**Why that is not yet enough to block a pin.**
`skills/optimize/measurement.md` states the rule this finding has not
met: "a release-gating regression on a single tight-loop or
fixed-overhead scenario needs reproduction across SEPARATE SESSIONS,
ideally days apart, before it blocks a pin or is written into a board
item as a finding," and gives the worked case where one unchanged
binary swung -38% between two sessions in the same container on the
same reported CPU after a regression had already reproduced across
seven interleaved isolated pairs. All six rounds above are ONE
session. Host placement is the term interleaving inside a session
cannot remove.

**The codec source is unchanged across the old range**
(`git log --oneline 07fc94a1c..354c17e08 -- net/http/encodebase64.c
net/http/decodebase64.c net/http/isbase64.c | wc -l` → `0`, in a
whilp/cosmopolitan checkout), and so is the binding
(`... -- tool/net/lfuncs.c tool/lua/lcosmo.c | wc -l` → `1`, which is
`354c17e08`'s `lcosmo.c` registration table entry for the new
`DecodeLua`, not the base64 path). The scenario's whole path is C:
`cosmic/codec.tl:36,77-87` calls `cosmo.EncodeBase64`,
`cosmo.IsBase64`, `cosmo.DecodeBase64`, each a thin wrapper
(`tool/net/lfuncs.c:913,946,950`). So layout, not codec source,
remains the leading hypothesis — but which range it must be hunted in
is now `07fc94a1c..fe7c36c4c`, not the old one.

**The harness supports every arm of this.** `_perf/run.tl` takes
`--only SUB` (substring, `_perf/run.tl:59,268`) and `--out FILE`, and
exits non-zero naming the miss when `--only` matches nothing
(`_perf/run.tl:282-286`). `_perf/gate.tl selfcheck A.json B.json
[--threshold PCT] <run args...>` measures the SAME binary twice and
passes run args through (`_perf/gate.tl:29-34`), which is the
same-binary noise floor this slice needs. The scenario is
`_perf/bench/micro_bench.tl:115-129` and its `check()` verifies the
round trip returns `BLOB`.

## Change

No source file changes. The deliverable is recorded evidence.

1. **Three arms, one fixed tree.** Work in three scratch worktrees of
   the cosmic checkout, all at cosmic commit **`5ef13f40`** — the same
   tree `3ISWHyP7` used, so the only differences from that run are the
   session, the container and the pin set:

   | arm | `3p/cosmos/cosmos_pin.tl` version | what it is |
   |---|---|---|
   | A | `2026.08.21-07fc94a1c` | the published release's pin, the gate's baseline arm |
   | B | `2026.08.24-354c17e08` | the pin `3ISWHyP7` accused |
   | C | `2026.08.26-fe7c36c4c` | main's pin today, the gate's current arm |

   In each worktree edit only the `version` and `platforms["*"].sha`
   lines of `3p/cosmos/cosmos_pin.tl` (the sha is the `cosmos.zip`
   asset's, taken from that release — never copied from a third
   party), then `bin/cosmic --make fetch && bin/cosmic --make build`.
   Read the `build: PASS` verdict line directly, never through a pipe.

   **If arm C refuses to build** — `5ef13f40` predates
   `bfe422e9` ("cosmos: consume the exact contracts"), so a newer
   runtime's `definitions.lua` may not agree with that tree's
   `_types/gentype.tl` MODULES list — then record the exact failure
   verbatim as a result, drop arm C, and run the slice as the two-arm
   A/B. Do NOT edit the tree to make arm C build: changing the tree
   breaks the "only the pin varies" property the whole measurement
   rests on. Do NOT substitute a different tree commit either; a
   changed tree makes this a different experiment, not this one.

2. **Record which binary each arm is.** `sha256sum o/bin/cosmic` in
   each worktree; the three (or two) hashes must differ. Quote them
   in the result. Never use `--version` to tell the arms apart — it
   stamps the pin at embed time, not the runtime
   (`skills/optimize/cosmopolitan.md` step 2).

3. **The noise floor, per arm, first.** In each worktree:

   ```
   o/bin/cosmic --make run _perf/gate.tl selfcheck \
     o/perf/aa-1.json o/perf/aa-2.json --only codec_base64_roundtrip_64k
   ```

   Run it twice per arm. Record the reported per-scenario delta of
   each pass — that is this container's same-binary swing for this
   scenario in THIS session, and it is what the decision rule in (5)
   measures the effect against.

4. **The readings.** Four isolated readings per arm, ALTERNATING
   between arms round-robin (A B C A B C A B C A B C — never all of
   one arm then all of the next), each its own process:

   ```
   o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k \
     --out o/perf/<arm>-<n>.json
   ```

   Use the default `--samples`/`--min-secs`. Nothing else heavy may
   run on the machine during the readings. Record every reading's
   µs/op and its reported `±`, in run order, in a table like the one
   under `## Evidence`.

5. **The verdict, by this rule and no other.** Let `med(X)` be an
   arm's median of its four readings and `floor` be the LARGEST
   same-binary delta any arm's selfcheck passes showed in (3). For
   each ordered arm pair (A→B, A→C, B→C) the regression is
   **REPRODUCED** iff all three hold:

   - `med(later) > med(earlier)`;
   - the two arms' four-reading ranges do not overlap;
   - `(med(later) - med(earlier)) / med(earlier) * 100 > floor`.

   Otherwise that pair is **NOT REPRODUCED**. State each pair's
   verdict with the three numbers that decided it. A→C is the pair
   that matters to the release lane; say so explicitly.

6. **Write the result onto this item.** Replace this spec sidecar
   (`gitboard spec 3ISlWFiS FILE`, run from the `board` worktree)
   with the same five sections unchanged plus a sixth, `## Result`,
   appended last. Do not delete `## Evidence` — a result that erases
   what it was measured against cannot be re-read. `## Result`
   carries, in this order and in these shapes, because `Acceptance`
   counts them:

   - one line per arm, starting at column 1, spelled exactly
     `- sha256 <arm> <64 hex digits>` — e.g.
     `- sha256 A 1b54fceb...`;
   - the selfcheck floor: each arm's two passes' reported
     per-scenario deltas, and the LARGEST of them named as `floor`;
   - the readings as one markdown table whose header and rows start
     at column 1 (`| run | arm | µs/op | ± |`), one row per reading,
     in run order;
   - one line per ordered arm pair reading
     `A→C: REPRODUCED — med 193.46 → 208.58 µs (+7.8%), ranges
     disjoint, floor 4.8%` or `A→C: NOT REPRODUCED — ...`, with the
     three numbers rule (5) decided on;
   - one closing paragraph saying what the evidence now supports and
     what it does not.

7. **File exactly the follow-up the result implies**, with
   `gitboard new "<title>" --parent 3HyRcW05 --spec-file F`, where F
   is one paragraph of evidence quoting the numbers:

   - **A→C reproduced** → file the bisect: which commit in
     `07fc94a1c..fe7c36c4c` moved it, by building
     `o//tool/lua/lua` in a whilp/cosmopolitan checkout at each
     candidate and standing it in at `o/3p/cosmos/lua`
     (`skills/optimize/cosmopolitan.md` step 2). Name the range and
     the commit count in the spec-file paragraph.
   - **A→C not reproduced** → file nothing new; say in `## Result`
     that the block reason recorded on `3ISVlHT6` no longer binds and
     leave the edge for the reviewer.

## Non-goals

- **No code change anywhere, and no PR.** This is a research slice:
  its deliverable is the `## Result` section and the follow-up item.
  Nothing lands on `main`, nothing lands in whilp/cosmopolitan.
- **Do not weaken, rename, resize or remove any scenario or its
  `check()`**, `codec_base64_roundtrip_64k` first among them, and do
  not add a `--samples`/`--min-secs` override to make readings
  cheaper. The `optimize` skill's standing rule.
- **Do not commit a pin change.** The three pin edits live in scratch
  worktrees and are never pushed. `bin/cosmic.pin` is untouched —
  that is `3ISVlHT6`.
- **Do not commit any `o/perf/*.json`**, and do not commit the
  worktrees.
- **Do not `gitboard unblock` anything.** Whether the reason recorded
  on `3ISVlHT6`'s edge still binds is a judgement the reviewer makes
  from the recorded result.
- **Do not dispatch `release.yml`**, with or without `perf_gate:
  false`. It publishes outward; it is a human's call.
- **Do not touch `_perf/gate.tl`, `_perf/compare.tl` or their
  tests.** D31 just landed there (`ef963bab`); a measurement pass is
  not the place to revisit it.
- **Do not change the cosmic tree in any arm.** Only the two pin
  lines differ between worktrees.

## Acceptance

A research slice has no PR, so acceptance is the recorded evidence
plus commands a reviewer re-runs. The sidecar this slice rewrites is
`o/board/items/3ISlWFiS7svcOfni0vzn6iFo8a9.md`, inside the `board`
worktree `skills/work/SKILL.md` bootstraps. Every check below reads
only the `## Result` section that slice appends, so it counts what
was measured and never what the spec itself says. `SEC` abbreviates
the extractor:

```
SEC="sed -n '/^## Result$/,$p' o/board/items/3ISlWFiS7svcOfni0vzn6iFo8a9.md"
```

Each command is written out in full below; run them from the cosmic
repo root.

- The section exists:
  `grep -c '^## Result$' o/board/items/3ISlWFiS7svcOfni0vzn6iFo8a9.md`
  → `1`. Today: `0`.
- One unindented table row per reading, plus its header:
  `sed -n '/^## Result$/,$p' o/board/items/3ISlWFiS7svcOfni0vzn6iFo8a9.md | grep -c '^| '`
  → at least `9` (four readings per arm × two arms, plus a header
  row), and at least `13` when arm C built. Today the command prints
  `0` because the section does not exist.
- One verdict word per ordered arm pair:
  `sed -n '/^## Result$/,$p' o/board/items/3ISlWFiS7svcOfni0vzn6iFo8a9.md | grep -c 'REPRODUCED'`
  → `3` when all three arms built (A→B, A→C, B→C), `1` when arm C was
  dropped. Today: `0`.
- The arms are distinguishable binaries:
  `sed -n '/^## Result$/,$p' o/board/items/3ISlWFiS7svcOfni0vzn6iFo8a9.md | grep -c '^- sha256 '`
  → `3`, or `2` when arm C was dropped, and the three hex digests on
  those lines must differ from one another. A repeated digest means
  two arms measured the same binary and the result is void. Today:
  `0`.
- The pin facts the result rests on re-run true:
  `git show d71d7f15:3p/cosmos/cosmos_pin.tl | grep version` prints
  `version = "2026.08.21-07fc94a1c"`, and
  `git show origin/main:3p/cosmos/cosmos_pin.tl | grep version`
  prints the version `## Result` names as arm C.
- Nothing was changed in the tree to get the numbers:
  `git status --short` prints nothing and
  `git diff --name-only origin/main` names nothing — no source
  change, no pin change, no `o/perf/*.json`, no committed worktree.
- The follow-up exists when the result calls for one: if A→C reads
  `REPRODUCED`, `## Result` names the new item's id, and
  `o/board/o/bin/gitboard show <that id>` prints a spec whose
  `## Evidence` quotes the A→C medians.

## Enablement

`none needed` — every instrument this slice uses exists and was
exercised today.

- The pin-swap A/B procedure is `skills/optimize/cosmopolitan.md`
  step 2 (the runtime stand-in and its three sharp edges: read the
  build verdict, never trust `--version`, hash the binary), and
  `3ISWHyP7` ran the same procedure on the same tree commit
  successfully.
- The noise-floor and reading commands are `_perf/gate.tl`'s
  `selfcheck` mode and `_perf/run.tl`'s `--only`/`--out`, both cited
  by line under `## Evidence`.
- The decision rule in (5) is arithmetic over numbers those two
  commands print; nothing has to be judged.
- For the bisect follow-up, should it be filed: a whilp/cosmopolitan
  checkout builds in this container class —
  `make -j$(nproc) o//tool/lua/lua` fetched the cosmocc toolchain
  into `.cosmocc/` over the network and ran to completion on
  2026-08-26. That is context for the follow-up's own refinement, not
  work this slice does.

The one judgement a literal-minded session could get wrong — quietly
changing the tree, the scenario, or the sample counts to make an arm
build or an effect show — is walled in `Non-goals`, and `Change` (1)
states the exact fallback for the one build failure that is actually
expected.
