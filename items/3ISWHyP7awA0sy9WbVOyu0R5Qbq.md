## Goal

G9 — every release publishes, measured. `release.yml`'s perf gate has
refused to publish since 2026-08-24 on two flagged scenarios. This
slice decides, by measurement, whether the cosmos pin bump `ea71d799`
caused them. EVIDENCE ONLY: it lands no product code and opens no pull
request; the deliverable is the recorded numbers and the follow-up
items they select (`skills/work/decompose.md`, "if a slice cannot be
sized without research, the research IS the slice").

**The measurement is DONE and recorded below.** What is left is the
handover: the board grew the phase this shape needs — `gitboard move
ID check --evidence`, landed 2026-08-26 as PR #1417 on the `board`
branch — so the deliverable can now reach a reviewer. The `Change`
section below is therefore the verification-and-handover, not a re-run.

## Evidence

The gate's report from the 2026-08-25 release run (32818853162),
against baseline `2026-08-23-d71d7f1`, after its retry AND its A/A
triage:

- `json_decode_large` 798.63µs -> 891.35µs (+11.6%, noise ±10.0%)
- `codec_base64_roundtrip_64k` 132.05µs -> 159.82µs (+21.0%, noise ±10.0%)

`release.yml:156-188` measures the previous release binary and the new
build in the SAME job on the SAME runner, so "different runner" is not
a free explanation.

Measured 2026-08-26 at cosmic `main` `ec794d44`, from each repo's root.

**Neither hot path has a source change behind it.**
`_perf/bench/json_bench.tl:55-72` calls `json.decode`, which
`cosmic/json.tl` forwards to `cosmo.DecodeJson`;
`_perf/bench/micro_bench.tl:114-129` calls `codec.encode_base64` /
`decode_base64`, which `cosmic/codec.tl:37,83` forwards to
`cosmo.EncodeBase64` / `cosmo.DecodeBase64`. The cosmos pin moved once
in the window, in `ea71d799` (2026-08-24, PR #1362):
`git show ea71d799 -- 3p/cosmos/cosmos_pin.tl` → `2026.08.21-07fc94a1c`
(sha `03e5286bce12d1080f00cdd1f2a72f634b6b0b7c0ce4e2287205d63221ef6f03`)
becomes `2026.08.24-354c17e08` (sha
`eae5513bc5283b684e51e6524080985505836f76c5a398f0c8c5ee68cedde380`). In
whilp/cosmopolitan across that exact range:

- `git log --oneline 07fc94a1c..354c17e08 -- tool/net/ljson.c
  third_party/lua/luadecodejsondata.c net/http/encodebase64.c
  net/http/decodebase64.c net/http/isbase64.c` → **no commits**. Both
  hot paths are byte-identical across the bump.
- `git log --oneline 07fc94a1c..354c17e08` → five commits, of which only
  `354c17e0` ("DecodeLua: a Lua-literal data parser in C, beside the
  JSON one", PR #274) changes what the binary contains:
  `git show --stat 354c17e0` → +991 lines, all additions, adding
  `tool/net/llua.c` (650 lines) as a new translation unit plus its
  `BUILD.mk` entry.

So the leading hypothesis is **binary layout** — a new translation unit
shifted code, with no algorithmic change anywhere.

## Result

**The handover question is settled: option 1.** An earlier pass of
this slice was returned to `plan` because `gitboard move 3ISWHyP7
check` answered `REFUSED: a handover to check names its PR — pass --pr
N`, and this spec opens no pull request. Three candidates were put on
the board; the one taken was **the board grows the handover** — filed
as `3ISltQMh` under G8, built as PR #1417, merged into `board` as
`c2b5edde` on 2026-08-26. `gitboard help move` now lists `--evidence`
("hand over recorded findings instead of a PR; the spec's ## Result
section is what the reviewer reads"), and an `accept` on a PR-less
item ends it rather than parking it in `land`. So this item hands over
with `--evidence`, and nothing about the measurement below changed.

Two consequences that bind this sidecar's SHAPE, both checked by the
tool rather than by prose:

- the heading must be exactly `## Result` — `_work/spec.tl`'s
  `section_of` matches the heading text case-insensitively and
  exactly, so `## Result (2026-08-26, this slice)` reads as no Result
  section at all and the handover is refused;
- no `###` sub-heading may appear inside it — `section_of` breaks at
  the NEXT heading of any depth, so a sub-heading truncates the
  section to its first line. The bold paragraph leads below are what
  structures it instead.

**The A/B ran as the earlier `## Change` specified.** Worktree at
`ea71d799^` (`5ef13f40`), only `3p/cosmos/cosmos_pin.tl` varied, six
rounds alternating `0821, 0824, 0821, 0824, 0821, 0824`, each round
rebuilt (`build: PASS (515 files, 1 binary)` every time) and measured
with two isolated single-scenario runs.

`json_decode_large` (`--only json_decode_large`):

| round | pin | ms/op | ± |
|---|---|---|---|
| 1 | 07fc94a1c | 1.26 | 16.0% |
| 2 | 354c17e08 | 1.11 | 8.0% |
| 3 | 07fc94a1c | 1.67 | 15.4% |
| 4 | 354c17e08 | 1.24 | 7.5% |
| 5 | 07fc94a1c | 1.19 | 15.9% |
| 6 | 354c17e08 | 1.24 | 7.2% |

Medians 1.26 → 1.24 ms. The newer cosmos is if anything FASTER, and
markedly more stable (±7–8% against ±15–16%). The sides overlap
completely. **Verdict: the pin is exonerated** — this is the "two sides
overlap" branch, consistent with the earlier finding that this scenario
reads +12.6% against itself in suite context and drifts ~11% between
isolated runs.

`codec_base64_roundtrip_64k` (`--only codec_base64_roundtrip_64k`):

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
reading (196.18). **Verdict: reproduces** — this is the "0824 side is
slower" branch. Stated honestly with its caveat: the per-run ± exceeds
the effect on the noisy rounds, so the separation rests on the
three-per-side ranges rather than any single pair, and the effect here
(+7.8%) is well under the release lane's +21.0%. Confirming on quieter
hardware is the first step of the follow-up.

Since the base64 codec is byte-identical across the bump
(`## Evidence`), the cause is what `354c17e0` did to the binary — a new
650-line translation unit — not to the codec.

**Follow-ups filed:**

- `3ISlWFiS` (`--repo whilp/cosmopolitan`) — the base64 regression,
  carrying all six readings, the bisect range `07fc94a1c..354c17e08`,
  and a cheapest-first plan (confirm on quiet hardware → bisect the
  five commits → check symbol alignment before touching source).
- `3ISlY5Xl` — the release gate's hole: it enforces a fixed 10% bar
  plus ONE A/A triage pass, so a scenario quiet in that pass and noisy
  later reads as a regression. The record must not excuse
  `json_decode_large` in a way that would also excuse base64's real
  +7.8%.

**Two deliberate deviations from the earlier `## Change` that ran the
A/B, both recorded rather than silent:**

1. **That Change's step 5 `perf_gate: false` dispatch was NOT run.** It publishes a
   release outward, and this slice ran unattended; the spec's own
   authority for it is `release.yml:148-155`, not a standing decision
   by anyone. It is left for a human, and it should be gated on
   `3ISlWFiS` — do not re-baseline the gate over a regression that is
   now confirmed real until that item has an answer or an accepted
   explanation.
2. **`gitboard block <this id> 3ISlWFiS` was NOT created.** That edge
   was written for the earlier design in which this item also did the
   re-baseline. This item's own work — the evidence — is complete, so
   blocking it would strand a finished slice; the block belongs on
   whatever item takes the re-baseline.

**Gate state**: `bin/cosmic --make ci` at `main` `ec794d44` →
`ci: PASS (5 stages)`. `git worktree list` no longer names `o/ab`;
`git status --porcelain` at the root is empty.


**The first attempt, 2026-08-26 — the noise characterisation the A/B
rests on.**

Measured on a 4-core session container (`nproc` → 4) at `main`
`ec794d44`, pin `2026.08.26-fe7c36c4c`, `build: PASS (536 files, 1
binary)`.

**Full-suite A/A is not quiet here.** `_perf/gate.tl selfcheck` (2m26s)
→ `perf-selfcheck: the scenarios flagged above vary by more than the
bar on noise alone`, `48 scenarios: 7 regression, 1 faster, 40 ok`. The
same binary flagged `json_decode_large` 1.21 ms -> 1.36 ms **+12.6%**
against ITSELF (also `tar_extract_tree` +48.5%, `fs_walk_tree` +21.1%,
`teal_check_module` +19.2%, `literal_format_pin` +17.6%,
`literal_parse_pin` +11.9%, `format_module_source` +10.2%).
`codec_base64_roundtrip_64k` read +2.0% — **ok**.

**Isolated A/A separates them.** Per `measurement.md`'s tie-breaker
(and note the flag must come AFTER both path arguments, or `--make run`
reads them as module names and dies with `require …: module not
found`):

- `--only json_decode_large` round 1: 1.14 -> 1.14 ms **+0.5%**, ±2.9%
- `--only json_decode_large` round 2: 1.27 -> 1.23 ms **-3.1%**
- `--only codec_base64_roundtrip_64k`: 216.60 -> 209.58 µs **-3.2%**, ±3.0%

all three → `perf-selfcheck: nothing exceeded the bar`. Within a call
both are quiet (±3%); ACROSS calls `json_decode_large` drifts 1.14 →
1.27 ms, about **11%** — the size of the release lane's flag — while
base64 stays inside 3.5%.

**Why this slice uses an old-tree worktree.** Holding `main` fixed and
reverting the pin is not an experiment that exists: `ea71d799` moved
`cosmic.literal` onto `cosmo.DecodeLua` in the same commit that bumped
the pin, and `DecodeLua` is added by `354c17e0` itself. `main` built
against `2026.08.21-07fc94a1c` → `build: FAIL (536 files)`,
`cosmic/literal.tl:29:26: error: invalid key 'DecodeLua' in record
'cosmo'`.

**The corrected experiment was verified runnable, both sides**, on
2026-08-26:

- `git worktree add -f o/ab ea71d799^` → detached at `5ef13f40`, whose
  committed pin is already `2026.08.21-07fc94a1c`.
- In it, `bin/cosmic --make fetch && bin/cosmic --make build` →
  `build: PASS (515 files, 1 binary)`, 1m16s cold.
- Swapping that worktree's pin to `2026.08.24-354c17e08` and rebuilding
  → `build: PASS (515 files, 1 binary)`, 15s incremental — only the
  cosmos base is refetched and restamped, so **the two binaries differ
  by the cosmos base and nothing else**, which is exactly the isolation
  this question needs.


**Verified at pull, 2026-08-26.** The two follow-ups the evidence
selected are both still on the board and open: `gitboard show
3ISlWFiS` → `gitboard-show: 3ISlWFiS is backlog`, `gitboard show
3ISlY5Xl` → `gitboard-show: 3ISlY5Xl is backlog`. Neither has been
ended or re-scoped, so nothing above needed correcting.

Both claims `## Evidence` rests on re-read clean from a
whilp/cosmopolitan checkout at `/home/user/cosmopolitan`:
`git log --oneline 07fc94a1c..354c17e08 -- tool/net/ljson.c
third_party/lua/luadecodejsondata.c net/http/encodebase64.c
net/http/decodebase64.c net/http/isbase64.c` printed NOTHING — both hot
paths are byte-identical across the pin bump — and
`git log --oneline 07fc94a1c..354c17e08` printed exactly five commits:
`354c17e0` (DecodeLua, PR #274), `8dd093ce` (EncodeJson float
formatting, PR #273), `5bfcf79d` (zipos handle recycling, PR #272),
`8e071ec9` (sqlite3 header stubs, PR #270) and `bf92718a` (AGENTS.md,
PR #269). The binary-layout hypothesis stands unchanged: `354c17e0` is
the only one of the five that adds a translation unit.

At the cosmic root, `git status --porcelain` is empty and `git worktree
list` names no `o/ab` — this slice edited no product file.

**Handover blocked again, 2026-08-26 — by the tool, not the evidence.**
`## Change` step 4 ran and was refused:

```
$ o/bin/gitboard move 3ISWHyP7 check --evidence
gitboard-move: REFUSED: cannot read PR #0: GET /repos/whilp/cosmic/pulls/0:
  HTTP 404: Not Found; --force to hand it over anyway
```

PR #1417 added the `--evidence` branch above `_work/gitverbs.tl`'s
unconditional `gate.handover_refusal(...)` call and left that call in
place, so an evidence handover still asks GitHub about PR #0. Filed as
`3IStqRsf`, which this item now waits on; `gitboard block 3ISWHyP7
3IStqRsf` records it. Nothing about the measurement changed and step 4
needs no rewrite — it becomes runnable the moment `3IStqRsf` lands.
`--force` is deliberately NOT used: it would skip the `## Result` check
that `--evidence` exists to impose, and the `work` skill reserves
forcing for repair.

**Verified again at pull, 2026-08-26 — the blocker landed and the
handover ran.** `3IStqRsf` (PR #1418, squash-merged into `board` as
`7a2f3e4e`) fixed the check gate: `cmd_move` now runs
`gate.handover_refusal` only when a PR number is in hand, so an
evidence handover no longer asks GitHub about PR #0. Step 4 below
needed no rewrite. On the diagnosability question this item's
`## Enablement` asked to be answered in the handover: the refusal that
blocked the earlier attempt was `cannot read PR #0: GET
/repos/whilp/cosmic/pulls/0: HTTP 404: Not Found`, which names the
GitHub read and not the sidecar — it is diagnosable as a tool defect,
but it says nothing about the `## Result` grammar, so the separate
friction about `section_of` being exact-match and depth-blind is
untouched by this fix and remains worth a capture if it recurs.

Step 1 re-read both follow-ups and both are still on the board and
open: `gitboard show 3ISlWFiS` → `gitboard-show: 3ISlWFiS is backlog`,
`gitboard show 3ISlY5Xl` → `gitboard-show: 3ISlY5Xl is backlog`.
Neither has been ended or re-scoped, so nothing above needed
correcting.

Step 2 re-read both `## Evidence` claims from the whilp/cosmopolitan
checkout at `/home/user/cosmopolitan`, freshly fetched:
`git log --oneline 07fc94a1c..354c17e08 -- tool/net/ljson.c
third_party/lua/luadecodejsondata.c net/http/encodebase64.c
net/http/decodebase64.c net/http/isbase64.c` printed NOTHING, and
`git log --oneline 07fc94a1c..354c17e08` printed exactly the same five
commits as before: `354c17e08` (DecodeLua, #274), `8dd093cea`
(EncodeJson float formatting, #273), `5bfcf79d0` (zipos handle
recycling, #272), `8e071ec98` (sqlite3 header stubs, #270) and
`bf92718a1` (AGENTS.md, #269). Both hot paths remain byte-identical
across the pin bump and the binary-layout hypothesis stands unchanged.

At the cosmic root `git status --porcelain` is empty and `git worktree
list` names no `o/ab`; this slice edited no product file.

## Change

The measurement is complete and recorded in `## Result`. Nothing is
re-run and nothing is built. What this slice does now is verify that
the recorded evidence still describes the tree, then hand the findings
over as evidence. No file in the product tree is edited; the only
writes are to this item's own sidecar on the `board` branch.

1. **Re-read the two follow-ups the evidence selected** and confirm
   both are on the board and still open:

   ```
   cd o/board && o/bin/gitboard show 3ISlWFiS
   cd o/board && o/bin/gitboard show 3ISlY5Xl
   ```

   `3ISlWFiS` carries the base64 regression against
   whilp/cosmopolitan (the bisect range `07fc94a1c..354c17e08` and the
   six readings); `3ISlY5Xl` carries the release gate's one-A/A-pass
   hole. If either has been ended or re-scoped since, say so in a
   sentence appended to `## Result` under a bold lead — do not re-file
   it and do not re-measure.

2. **Confirm the tree still matches the two claims `## Evidence`
   rests on**, both of which are history and cannot drift, so this is
   a read, not a re-measurement:

   ```
   git log --oneline 07fc94a1c..354c17e08 -- tool/net/ljson.c \
     third_party/lua/luadecodejsondata.c net/http/encodebase64.c \
     net/http/decodebase64.c net/http/isbase64.c
   git log --oneline 07fc94a1c..354c17e08
   ```

   Run these from a whilp/cosmopolitan checkout (this repo's sibling;
   the session's own path for it is not fixed, so `cd` there first).
   The first must print nothing; the second must print five commits.
   If no whilp/cosmopolitan checkout is available in the session,
   record that it could not be re-read rather than asserting it — the
   claims are history and cannot have changed, so this is corroboration,
   not a gate.

3. **Append a dated verification note to `## Result`** — one bold-led
   paragraph naming what step 1 and step 2 returned, and the date —
   then replace the sidecar with `gitboard spec 3ISWHyP7 FILE`. Keep
   the heading exactly `## Result` and introduce no `###` heading
   inside it: `_work/spec.tl`'s `section_of` matches the heading text
   exactly and breaks at the next heading of any depth, so either
   would make the handover in step 4 refuse.

4. **Hand over as evidence**:

   ```
   cd o/board && o/bin/gitboard move 3ISWHyP7 check --evidence
   ```

   No PR is opened, on either repo. The reviewer reads `## Result`.

## Non-goals

- **Do NOT re-run the A/B.** It is done and its twelve readings are in
  `## Result`. Re-running it costs two rebuilds and six measured runs
  and answers a question already answered.
- **Do NOT open a pull request**, on whilp/cosmic or on
  whilp/cosmopolitan. This slice's deliverable is evidence; PR #1417
  is what made that handover possible and is already merged.
- **Do NOT dispatch `release.yml` with `perf_gate: false`.** It
  publishes a release outward and this slice runs unattended. It is a
  human's call, and it should wait on `3ISlWFiS` — do not re-baseline
  the gate over a regression now confirmed real.
- **No scenario or `check()` is weakened, renamed, or removed** — not
  `json_decode_large`, not `codec_base64_roundtrip_64k`, not their
  input sizes. The `optimize` skill's standing rule.
- **The gate's threshold is not changed** here or anywhere without a
  decision record. Widening `--threshold`, or adding either scenario
  to the gate's noise-excused set, is the "weaken it until it passes"
  move this item exists to avoid.
- **The cosmos pin at `main` is not touched, and is not a fix.** `main`
  cannot build against the pre-bump cosmos (`## Result`), and later
  pins carry `cosmo.DecodeLua`, which `cosmic.literal` now requires. A
  real regression is fixed in whilp/cosmopolitan.
- **No `o/perf/*.json` is committed** and no `o/ab` worktree is
  re-created.
- **Do not chase the other six scenarios** the full-suite A/A flagged
  (`tar_extract_tree`, `fs_walk_tree`, `teal_check_module`,
  `literal_format_pin`, `literal_parse_pin`, `format_module_source`).
  They are this container's next question, not this slice's; if they
  still look worth a look at the end, file one capture and stop.

## Acceptance

Run from the cosmic repo root unless stated.

- `cd o/board && o/bin/gitboard show 3ISlWFiS` ends
  `gitboard-show: 3ISlWFiS is backlog` and `... show 3ISlY5Xl` ends
  `gitboard-show: 3ISlY5Xl is backlog` (both measured 2026-08-26; any
  phase but an ended one satisfies this — what it proves is that the
  follow-ups the evidence selected are still on the board).
- `git status --porcelain` at the cosmic root → empty. This slice
  edits no product file, so this is the proof of it.
- `git worktree list` does not name `o/ab`.
- `cd o/board && o/bin/gitboard show 3ISWHyP7` prints a `## Result`
  carrying the twelve readings (six per scenario) and the dated
  verification note step 3 appends.
- The sidecar's Result heading is exactly `## Result` and carries no
  sub-heading:
  `grep -c '^## Result$' o/board/items/3ISWHyP7awA0sy9WbVOyu0R5Qbq.md` → `1`, and
  `awk '/^## Result$/{f=1;next} /^#/{f=0} f' o/board/items/3ISWHyP7awA0sy9WbVOyu0R5Qbq.md
  | grep -c '^#'` → `0`.
- `cd o/board && o/bin/gitboard move 3ISWHyP7 check --evidence` ends
  `gitboard-move: 3ISWHyP7 do -> check` — the verb REFUSES the handover
  when `## Result` is missing or empty, which is what makes the two
  commands above the contract and not a style note.

## Enablement

`none needed`. The one blocker is landed: `3ISltQMh` (PR #1417,
`board` `c2b5edde`) added `move … --evidence` and made an `accept` on
a PR-less item end it, which is the whole mechanism this handover
needs; `o/bin/gitboard help move` lists the flag.

`skills/optimize/SKILL.md` carries the loop and
`skills/optimize/measurement.md` the noise discipline, both already
applied in `## Result`; nothing here re-measures, so neither is on the
critical path any more.

Two frictions found while refining this, worth captures if they recur:

- `--make run _perf/gate.tl selfcheck --only NAME A B` fails with
  `require A: module 'A' not found`; the flag must follow the two path
  arguments, while `measurement.md:85-92` shows it in the other order.
- `_work/spec.tl`'s `section_of` is exact-match and depth-blind, so a
  `## Result (dated)` heading or a `###` inside the section silently
  reads as "no findings" at the `--evidence` gate. This item's first
  sidecar had both. Say in the handover whether the refusal message
  made that diagnosable.
