## Goal

The outcome this serves is the release perf gate's measured half — the
`perf-compare` ratchet named in `docs/goals.md`'s **G6 — the defining
paths, ratcheted**. (This item is currently parented under G3 and its
sibling specs cite a "G9 — every release publishes, measured" that is
not in `docs/goals.md`; that mis-parenting is capture `3IT8rb3B` and is
NOT this slice's to fix.)

`codec_base64_roundtrip_64k` is one of the two scenarios that has kept
`release.yml`'s perf gate red since 2026-08-24 — the other,
`json_decode_large`, was exonerated as machine variance under
`3ISWHyP7` and the gate hole that let it hold a release was closed by
`3ISlY5Xl` (PR #1419, merged). This one is REAL and reproducible, and
until it has an answer no release publishes. EVIDENCE ONLY: this slice
lands no code and opens no pull request, in either repo. The
deliverable is the recorded numbers and the follow-up items they
select.

## Evidence

**The regression, measured 2026-08-26 under `3ISWHyP7`** on a 4-core
container. The A/B held the cosmic tree fixed at `ea71d799^`
(`5ef13f40`) in a worktree and varied ONLY `3p/cosmos/cosmos_pin.tl`,
so the two binaries differ by the cosmos base and nothing else. Six
rounds, alternating sides, each an isolated single-scenario run
(`o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k`):

| round | pin | µs/op | ± |
|---|---|---|---|
| 1 | 07fc94a1c | 191.73 | 14.2% |
| 2 | 354c17e08 | 227.05 | 9.8% |
| 3 | 07fc94a1c | 196.18 | 13.1% |
| 4 | 354c17e08 | 206.34 | 7.0% |
| 5 | 07fc94a1c | 193.46 | 4.8% |
| 6 | 354c17e08 | 208.58 | 3.3% |

Medians 193.46 → 208.58 µs, **+7.8%**, slower on `354c17e08` in all
three pairings, and the two sets do not overlap — the fastest
`354c17e08` reading (206.34) is slower than the slowest `07fc94a1c`
reading (196.18). The release lane read +21.0% on the same scenario.
Caveat kept: the per-run ± exceeds the effect on the noisy rounds, so
the separation rests on the three-per-side ranges rather than any
single pair.

**The codec source is byte-identical across the bump.** From a
whilp/cosmopolitan checkout, `git log --oneline
07fc94a1c..354c17e08 -- net/http/encodebase64.c net/http/decodebase64.c
net/http/isbase64.c` prints NOTHING (re-read 2026-08-26). So this is
not an algorithmic change to the codec.

**What DID change: three of the range's five commits change compiled
code.** Read per commit with `git show --stat <sha>` — the unfiltered
per-commit stat, which is what this claim requires; a path-filtered
`git log` cannot support it:

- `354c17e08` (DecodeLua, #274) → 7 files, +991, all additions:
  `tool/net/llua.c` (650 lines) as a NEW translation unit,
  `tool/lua/lcosmo.c` (+23), two `BUILD.mk` entries.
- `8dd093cea` (EncodeJson float formatting, #273) →
  `third_party/lua/luaencodejsondata.c` (+11/-1), compiled in.
- `5bfcf79d0` (zipos stored-member handle recycling, #272) →
  `libc/runtime/zipos-open.c` (+62/-9), `zipos.internal.h` (-1) — a
  behavioural change to the zip filesystem READ path.

The other two are inert for compiled output, checked rather than
assumed: `8e071ec98` (#270) adds only `third_party/sqlite3/qrf.h` and
`tclsqlite.h` plus a `BUILD.mk` line, and both `#include`s naming them
sit in preprocessor branches no compiler here takes
(`sqlite3.c:203324` under `SQLITE_TEST`, never defined in this tree;
`shell.c:898` under `#ifndef SQLITE_QRF_H`, whose guard the copy
inlined at `shell.c:678-881` already defines). `bf92718a1` (#269)
touches `AGENTS.md` alone.

Oldest-first, the range is: `bf92718a1`, `8e071ec98`, `5bfcf79d0`,
`8dd093cea`, `354c17e08`.

**"Not on the base64 path" does not dismiss the other two.** The
hypothesis under test is code LAYOUT, and any commit that changes
compiled code shifts layout — that is the mechanism, not a side
effect. `skills/optimize/cosmopolitan.md:132-141` records this as the
layer's single most common false alarm: "a C edit relinks the whole
binary, so function addresses shift and unrelated fixed-overhead
microbenchmarks routinely trip the regression bar on layout noise
alone." So all three binary-changing commits are live candidates and
the question this slice answers is WHICH.

**The measurement mechanism exists and needs no release.**
`skills/optimize/cosmopolitan.md:47-68`: a cosmic binary is its
payload embedded onto whatever runtime sits at `o/3p/cosmos/lua`, so
`cp $COSMO/o/tool/lua/lua o/3p/cosmos/lua && bin/cosmic --make build`
stands a locally built lua in. That is what makes intermediate commits
measurable at all — only `07fc94a1c` and `354c17e08` were ever
published as cosmos releases, so pin-swapping cannot reach the three
points between them.

**The cosmic side must be the OLD tree, and that is proven.** cosmic
`main` requires `cosmo.DecodeLua`, which `354c17e08` itself adds, so
`main` cannot build against any runtime from earlier in the range
(`3ISWHyP7` recorded `build: FAIL (536 files)`,
`cosmic/literal.tl:29:26: error: invalid key 'DecodeLua' in record
'cosmo'`). The worktree at `ea71d799^` (`5ef13f40`) predates that
dependency and `3ISWHyP7` built it successfully against BOTH endpoints
(`build: PASS (515 files, 1 binary)` each). The three intermediate
points differ from those endpoints only by non-surface changes: of the
three binary-changing commits only `354c17e08` touches
`tool/net/definitions.lua` with new surface (+26), while `8dd093cea`'s
`definitions.lua` diff (+4) is doc-comment text inside the existing
`cosmo.EncodeJson` block and adds no binding — so the type generator's
MODULES ratchet
(`skills/optimize/cosmopolitan.md:87-95`) has nothing to catch at any
intermediate point.

**Host capacity, measured 2026-08-26**: `df -h /home/user` → 28G
available; `.cosmocc` toolchain is 1.3G once downloaded.

## Change

Locate the regression to ONE of the three binary-changing commits by
measuring four build points in a single interleaved rotation. Nothing
is fixed and no source is edited in either repo.

1. **Set up the two checkouts.**

   ```
   COSMO=/home/user/cosmopolitan
   COSMO_START_BRANCH=$(git -C $COSMO rev-parse --abbrev-ref HEAD)
   cd /home/user/cosmic && git worktree add -f o/ab ea71d799^
   cd o/ab && bin/cosmic --make fetch && bin/cosmic --make build
   ```

   The last command must end `build: PASS (515 files, 1 binary)`. Keep
   the pinned runtime aside first —
   `cp o/3p/cosmos/lua o/3p/cosmos/lua.pinned` — per
   `skills/optimize/cosmopolitan.md:60-68`.

2. **The four build points**, oldest first. `bf92718a1` and
   `8e071ec98` are deliberately NOT measured because `## Evidence`
   establishes they change no compiled output; state that skip in the
   findings rather than leaving it silent.

   | point | commit | what it adds relative to the previous point |
   |---|---|---|
   | P0 | `07fc94a1c` | range base |
   | P1 | `5bfcf79d0` | zipos read-path rework |
   | P2 | `8dd093cea` | JSON encoder float formatting |
   | P3 | `354c17e08` | DecodeLua, a new 650-line translation unit |

3. **Measure them in one interleaved rotation, four rounds.** Rotate
   P0, P1, P2, P3 in order and repeat four times, so slow host drift
   hits all four points equally — this is
   `skills/optimize/cosmopolitan.md:144-172`'s interleave, widened
   from a pair to four points because the effect (+7.8%) lives under
   the 10% bar and no single compare can resolve it. Each cycle is:

   ```
   git -C $COSMO checkout <commit>
   make -C $COSMO -j$(nproc) o//tool/lua/lua
   cp $COSMO/o/tool/lua/lua o/3p/cosmos/lua
   bin/cosmic --make build            # must end `build: PASS`
   o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k \
     --out o/perf/<point>-r<round>.json _perf.bench.micro_bench
   ```

   Read `build: PASS` or the exit status directly, never through a
   pipe: a failed build leaves the PREVIOUS `o/bin/cosmic` in place and
   it measures happily
   (`skills/optimize/cosmopolitan.md:70-77`). Confirm each cycle
   actually swapped the runtime with `sha256sum o/bin/cosmic` — the
   embedded `--version` stamp is read from the pin and cannot identify
   a stood-in runtime (`skills/optimize/cosmopolitan.md:78-86`).

4. **Read the result as four readings per point.** Take each point's
   median. P0's own four readings are the noise floor: the spread among
   them is what any step-to-step difference must beat to mean anything.
   The regression is located at the FIRST step (P0→P1, P1→P2, P2→P3)
   whose median jump both exceeds that floor and holds its direction in
   at least three of the four rounds.

5. **Record the findings** in the sidecar under a `## Result` heading —
   exactly `## Result`, with no `###` inside it, because
   `_work/spec.tl`'s `section_of` matches the heading text exactly and
   breaks at the next heading of any depth, which would make the
   handover in step 7 refuse. Include all sixteen readings, the four
   medians, the located step, and the honest verdict — including "no
   step separates" if that is what the numbers say, which is itself a
   finding: it would mean the effect is distributed layout sensitivity
   rather than one commit's doing.

6. **File the follow-ups the findings select** as new items
   (`gitboard new "title" --spec-file F`), and say in the findings
   which were filed. At minimum: whichever commit is located gets an
   item carrying the readings and the bisect range; if no step
   separates, the item is against the SCENARIO's resolvability instead,
   and cosmic — not cosmopolitan — is where it lands.

7. **Tear down and hand over as evidence.**

   Record `$COSMO`'s starting branch BEFORE step 3 checks any commit
   out (`git -C $COSMO rev-parse --abbrev-ref HEAD`) and return it
   there — do NOT assume `master`, because a runner-provisioned
   checkout may sit on an assigned branch instead (it did during
   refinement: `claude/brave-fermat-iyvf23`).

   ```
   cd /home/user/cosmic && git worktree remove -f o/ab
   git -C $COSMO checkout "$COSMO_START_BRANCH"
   cd o/board && o/bin/gitboard move 3ISlWFiS check --evidence
   ```

## Non-goals

- **Do NOT fix anything.** No C change in whilp/cosmopolitan, no
  wrapper change in cosmic. This slice locates the cause; fixing it is
  the follow-up item step 6 files.
- **Do NOT open a pull request**, on either repo.
- **Do NOT weaken, rename, resize, or remove
  `codec_base64_roundtrip_64k` or its `check()`**, and do not change
  its input size. The `optimize` skill's standing rule.
- **Do NOT change the gate's threshold**, `TRIAGE_K`, or add any
  scenario to a noise-excused set. `3ISlY5Xl`/D31 settled how the gate
  reads noise and this slice does not reopen it.
- **Do NOT dispatch `release.yml` with `perf_gate: false`.** It
  publishes a release outward and this slice runs unattended; it is a
  human's call.
- **Do NOT bump `3p/cosmos/cosmos_pin.tl` or `bin/cosmic.pin`.**
- **Do NOT edit cosmic's tracked tree at all.** The only writes are the
  throwaway `o/ab` worktree, `o/` build output, and this item's own
  sidecar on the `board` branch. `git status --porcelain` at the cosmic
  root must be empty at the end.
- **Do NOT leave `$COSMO` on a detached commit** or with a modified
  working tree; step 7 returns it to `master`.
- **Do NOT commit any `o/perf/*.json`.**
- **Do NOT re-run the six-round pin A/B** in `## Evidence`. It is done
  and its numbers stand; this slice measures the four intermediate
  points, which that A/B could not reach.
- **Do NOT fix the G3/G9 mis-parenting** described in `## Goal`. It is
  capture `3IT8rb3B` and its re-parenting half is the goal owner's
  call.

## Acceptance

Run from the cosmic repo root unless stated.

- `cd o/board && o/bin/gitboard show 3ISlWFiS` prints a `## Result`
  section carrying **sixteen** readings — four per build point — the
  four medians, and a stated verdict naming either the located step or
  "no step separates".
- The Result heading is exactly `## Result` and carries no
  sub-heading:
  `grep -c '^## Result$' o/board/items/3ISlWFiS7svcOfni0vzn6iFo8a9.md` → `1`, and
  `awk '/^## Result$/{f=1;next} /^#/{f=0} f' o/board/items/3ISlWFiS7svcOfni0vzn6iFo8a9.md | grep -c '^#'`
  → `0`.
- The findings quote, for each of the sixteen cycles, the
  `sha256sum o/bin/cosmic` that produced it, and the sixteen hashes
  show four distinct values — one per build point. This is the proof
  that each cycle measured the runtime it claims and not a stale
  binary; identical hashes across two different points means a build
  silently failed and the numbers are void.
- `git status --porcelain` at the cosmic root → empty.
- `git worktree list` does not name `o/ab`.
- `git -C /home/user/cosmopolitan status --porcelain` → empty, and
  `git -C /home/user/cosmopolitan rev-parse --abbrev-ref HEAD` prints
  the branch name recorded at step 1 — a branch name, never a detached
  `HEAD`. State in the findings which branch that was.
- `git diff --name-only` in whilp/cosmopolitan against `master` → empty
  (nothing was edited to get the numbers).
- The findings name every commit in the range and say which were
  measured and which were skipped with why — no silent cap.
- `cd o/board && o/bin/gitboard move 3ISlWFiS check --evidence` ends
  `gitboard-move: 3ISlWFiS do -> check`. The verb REFUSES the handover
  when `## Result` is missing or empty, which is what makes the two
  heading checks above a contract and not a style note.

## Enablement

`none needed`. Every mechanism is documented and was verified present
on this host during refinement, 2026-08-26:

- **The cosmopolitan toolchain downloads and builds here — run, not
  assumed.** `/home/user/cosmopolitan` had no `.cosmocc` and no `o/`.
  `make -j$(nproc) o//tool/lua/lua` at `886741e06` fetched the
  toolchain (`.cosmocc`, 1.3G) through this environment's proxy and
  completed with **exit code 0** in about two minutes wall, producing
  `o/tool/lua/lua` (3,234,519 bytes), which runs:
  `o/tool/lua/lua -e 'print(_VERSION)'` → `Lua 5.4`. So the one
  prerequisite that could have made this slice unrunnable is
  discharged, and the toolchain is now warm on this host.
- **The runtime stand-in** (`cp … o/3p/cosmos/lua`, rebuild) is
  `skills/optimize/cosmopolitan.md:47-68`, and `o/3p/cosmos/lua`
  exists in a fetched cosmic checkout.
- **The interleave** is `skills/optimize/cosmopolitan.md:144-172`.
- **The old-tree requirement** and the three sharp edges (failed build
  leaves a stale binary, `--version` cannot identify the runtime, tree
  and runtime must agree on the `cosmo.*` surface) are
  `skills/optimize/cosmopolitan.md:70-95`, and `## Evidence` records
  why none of them binds at the intermediate points.
- **The `--evidence` handover** landed as `3ISltQMh` (PR #1417) and its
  PR-#0 defect was fixed by `3IStqRsf` (PR #1418, merged); it has since
  been used successfully on `3ISWHyP7`.

The one judgment a literal-minded session could get wrong — reading a
number off a build that silently failed, so two "different" points are
the same binary — is walled in `Change` step 3 and checked by the
four-distinct-hashes requirement in `Acceptance`.

Cost, from the measurements above rather than a guess: sixteen cycles,
each a cosmopolitan build at a checked-out commit (~2 min cold on this
host, and switching commits invalidates enough of `o/` that most
cycles will be nearer cold than warm) plus a cosmic rebuild
(`3ISWHyP7` measured ~15s incremental) and one isolated scenario run.
Call it roughly an hour of building plus the measurement runs — a
long slice, not an open-ended one. If it proves too large in practice,
the reduction to take is FEWER ROUNDS (three, not four) — never fewer
build points, since dropping a point is dropping a candidate, and say
in the findings that three rounds were run.
