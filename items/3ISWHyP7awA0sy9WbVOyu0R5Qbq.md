## Goal

G9 — every release publishes, measured. `release.yml`'s perf gate has
refused to publish since 2026-08-24 on two flagged scenarios. This
slice decides, by measurement, whether the cosmos pin bump `ea71d799`
caused them. EVIDENCE ONLY: it lands no product code and opens no pull
request; the deliverable is the recorded numbers and the follow-up
items they select (`skills/work/decompose.md`, "if a slice cannot be
sized without research, the research IS the slice").

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

## Result (2026-08-26, this slice)

**The A/B ran as `## Change` specifies.** Worktree at `ea71d799^`
(`5ef13f40`), only `3p/cosmos/cosmos_pin.tl` varied, six rounds
alternating `0821, 0824, 0821, 0824, 0821, 0824`, each round rebuilt
(`build: PASS (515 files, 1 binary)` every time) and measured with two
isolated single-scenario runs.

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

**Two deliberate deviations from `## Change`, both recorded rather than
silent:**

1. **Step 5's `perf_gate: false` dispatch was NOT run.** It publishes a
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

## Result (from the first attempt, 2026-08-26)

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

## Change

Run the A/B in the `ea71d799^` worktree, isolated and alternated, then
record and hand over. Nothing in the checked-out tree at `main` is
modified.

1. **Set up the worktree** (skip the add if `o/ab` already exists):

   ```
   git worktree add -f o/ab ea71d799^
   cd o/ab && bin/cosmic --make fetch && bin/cosmic --make build
   ```

   Expect `build: PASS (515 files, 1 binary)`. Everything below runs
   from `o/ab`.

2. **Six rounds, alternating sides**, starting with the pin the
   worktree already carries. One round is: set
   `3p/cosmos/cosmos_pin.tl` to that round's `version`/`sha` (values in
   `## Evidence`), then

   ```
   bin/cosmic --make fetch
   bin/cosmic --make build
   o/bin/cosmic --make run _perf/run.tl --out o/perf/r<N>-<pin>.json --only json_decode_large
   o/bin/cosmic --make run _perf/run.tl --out o/perf/r<N>-<pin>-b64.json --only codec_base64_roundtrip_64k
   ```

   Alternate `0821, 0824, 0821, 0824, 0821, 0824` so thermal drift
   lands on both sides equally — three measurements per scenario per
   side. Isolated `--only` runs are mandatory, not a shortcut: the
   `## Result` above shows this scenario pair reading +12.6% against
   ITSELF in suite context and ±3% in isolation.

3. **Read the six numbers per scenario directly** — median µs/op and ±
   from each run's report line. Do NOT run `_perf/gate.tl compare` over
   these files: `_perf/compare.tl:140` marks every scenario in the
   baseline and absent from the current run `missing`, and `:76` counts
   missing as a failure, so a single-scenario file compared against
   another single-scenario file is only meaningful when both carry the
   same one scenario — and the three-per-side shape is what the
   judgment needs, not one pairwise verdict.

4. **Restore and clean up**: `git checkout -- 3p/cosmos/cosmos_pin.tl`
   in `o/ab`, then from the repo root
   `git worktree remove --force o/ab`. Confirm `git status --porcelain`
   at the root is empty.

5. **Record** all six readings per scenario, plus the `perf-selfcheck:`
   verdict lines, into this item's `## Result` (`gitboard spec <id>
   FILE`). Then take the branch the numbers select, per scenario
   independently — the two scenarios have different evidence and may
   land on different branches:

   - **The 0824 side is slower than the 0821 side by more than both
     sides' spread, in all three pairings** → the cosmos bump regressed
     that scenario. File `gitboard new "<scenario>: +N% between cosmos
     07fc94a1c and 354c17e08" --repo whilp/cosmopolitan --spec-file F`,
     where F carries the six readings, the bisect range
     `07fc94a1c..354c17e08`, and the observation that neither hot path
     changed source in it (so `354c17e0`'s new translation unit is the
     first thing to test). Then `gitboard block <this id> <new id>`.
   - **The two sides overlap within their spreads** → the pin is
     exonerated for that scenario and the release lane's flag is
     machine variance. File `gitboard new "release perf gate: a layout
     shift reads as a regression for <scenario>" --spec-file F` naming
     the durable fix as a decision record under `skills/decide` — never
     a quietly widened threshold.
   - Once BOTH scenarios have landed on a branch and every follow-up is
     filed, dispatch `release.yml` ONCE with `perf_gate: false` to
     publish past the now-captured regression, which is what
     `release.yml:148-155` reserves that input for, and say in this
     item that it was dispatched and why. Do not dispatch while either
     scenario is still unexplained.

## Non-goals

- **No scenario or `check()` is weakened, renamed, or removed** — not
  `json_decode_large`, not `codec_base64_roundtrip_64k`, not their
  input sizes. The `optimize` skill's standing rule.
- **The gate's threshold is not changed** here or anywhere without a
  decision record. Widening `--threshold`, or adding either scenario to
  the gate's noise-excused set, is the "weaken it until it passes" move
  this item exists to avoid.
- **No product code and no pull request.** Nothing under `cosmic/`,
  `_cli/`, `_make/`, `_tool/` or `_perf/` is edited, at `main` or in the
  worktree. The only file edited anywhere is the worktree's
  `3p/cosmos/cosmos_pin.tl`, which step 4 restores before the worktree
  is removed.
- **The cosmos pin at `main` is not touched, and is not a fix.** `main`
  cannot build against the pre-bump cosmos (`## Result`), and later
  pins carry `cosmo.DecodeLua`, which `cosmic.literal` now requires. A
  real regression is fixed in whilp/cosmopolitan.
- **No `o/perf/*.json` is committed.** The numbers go into this
  sidecar as prose.
- **Do not chase the other five scenarios** the full-suite A/A flagged
  (`tar_extract_tree`, `fs_walk_tree`, `teal_check_module`,
  `literal_format_pin`, `literal_parse_pin`, `format_module_source`).
  They are this container's next question, not this slice's; if they
  still look worth a look at the end, file one capture and stop.

## Acceptance

Run from the cosmic repo root unless stated.

- In `o/ab`, on each pin: `bin/cosmic --make build` →
  `build: PASS (515 files, 1 binary)`.
- Six `o/bin/cosmic --make run _perf/run.tl --only <scenario> --out …`
  invocations per scenario complete, and their per-scenario report
  lines (`<name>  N x  <µs>/op  ± <pct>`) are quoted verbatim into this
  item's `## Result` — three readings per side per scenario, twelve in
  all.
- `git worktree list` no longer names `o/ab`, and
  `git status --porcelain` at the root → empty.
- `bin/cosmic --make ci` at the root → `ci: PASS (5 stages)`. Nothing
  at `main` changed, so this is the proof of it.
- `o/bin/gitboard show <this id>` prints a `## Result` carrying the
  twelve readings, and every follow-up item this slice filed appears in
  `o/bin/gitboard status`.

## Enablement

`none needed` for the measurement: `skills/optimize/SKILL.md` carries
the loop and `skills/optimize/measurement.md` the noise discipline,
whose isolated-re-measurement tie-breaker is what this slice's step 2
applies and is not optional for `json_decode_large`.

The blocker `3ISWHWQT` landed as PR #1415 (main `90f0a744`), so
`_perf/run.tl` type-checks under an older embedded env — which is what
lets the `ea71d799^` worktree's binaries run the harness at all.

Two frictions found while refining this, worth captures if they recur:

- `--make run _perf/gate.tl selfcheck --only NAME A B` fails with
  `require A: module 'A' not found`; the flag must follow the two path
  arguments, while `measurement.md:85-92` shows it in the other order.
- A research slice reaches `check` with `--pr` omitted, so its reviewer
  has only the item to read. This is the first on the board; say in the
  handover whether reviewing an evidence-only item worked.
