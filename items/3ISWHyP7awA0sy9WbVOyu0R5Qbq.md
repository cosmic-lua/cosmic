## Goal

G9 — every release publishes, measured. `release.yml`'s perf gate has
refused to publish since 2026-08-24, and the two scenarios it flags are
unexplained. This slice is EVIDENCE ONLY: it decides, by measurement,
whether the two deltas belong to the cosmos pin or to the release
runner, and hands the answer to a follow-up. It lands no product code
and opens no pull request — the deliverable is the recorded numbers and
the item that acts on them (`skills/work/decompose.md`, "if a slice
cannot be sized without research, the research IS the slice").

## Evidence

The gate's own report, from the 2026-08-25 release run (32818853162),
against baseline `2026-08-23-d71d7f1`, after the gate's retry AND its
A/A triage:

- `json_decode_large` 798.63µs -> 891.35µs (+11.6%, noise ±10.0%)
- `codec_base64_roundtrip_64k` 132.05µs -> 159.82µs (+21.0%, noise ±10.0%)
- 9 scenarios got faster (literal parse -97% among them).

Both survive the gate's own noise handling, so "flaky runner" is not a
free explanation: `release.yml:156-188` measures the PREVIOUS release
binary and the new build in the SAME job on the SAME runner, then runs
one A/A self-check to triage. That is why this needs an answer rather
than a re-run.

Measured 2026-08-26 at cosmic `main` `ec794d44`, from each repo's root.

**Neither hot path has a source change behind it.** Both scenarios go
straight into cosmo C bindings — `_perf/bench/json_bench.tl:55-72` calls
`json.decode`, which `cosmic/json.tl` forwards to `cosmo.DecodeJson`;
`_perf/bench/micro_bench.tl:114-129` calls `codec.encode_base64` /
`decode_base64`, which `cosmic/codec.tl` forwards to the cosmo codec
bindings. In the window, the cosmos pin moved exactly once, in
`ea71d799` (2026-08-24, PR #1362):
`git show ea71d799 -- 3p/cosmos/cosmos_pin.tl` →
`version 2026.08.21-07fc94a1c` (sha
`03e5286bce12d1080f00cdd1f2a72f634b6b0b7c0ce4e2287205d63221ef6f03`)
becomes `2026.08.24-354c17e08` (sha
`eae5513bc5283b684e51e6524080985505836f76c5a398f0c8c5ee68cedde380`).
In whilp/cosmopolitan, across that exact range:

- `git log --oneline 07fc94a1c..354c17e08 -- tool/net/ljson.c
  third_party/lua/luadecodejsondata.c net/http/encodebase64.c
  net/http/decodebase64.c net/http/isbase64.c` → **no commits**. The
  JSON decoder and the base64 codec are byte-identical across the bump.
- `git log --oneline 07fc94a1c..354c17e08` → five commits. The only one
  that changes what the binary CONTAINS is `354c17e0` ("DecodeLua: a
  Lua-literal data parser in C, beside the JSON one", PR #274):
  `git show --stat 354c17e0` → +991 lines, all additions, adding
  `tool/net/llua.c` (650 lines) as a new translation unit plus its
  `BUILD.mk` entry. `8dd093ce` touches only the ENCODE path
  (`third_party/lua/luaencodejsondata.c`), and `json_encode_large` was
  not flagged; `5bfcf79d` touches `libc/runtime/zipos-open.c`, which
  neither scenario reaches.

So the leading hypothesis is **binary layout**: a new translation unit
shifted code and moved two hot loops across a cache or alignment
boundary, with no algorithmic change anywhere. The competing hypothesis
is that something else in the cosmos build did regress them. This slice
separates the two.

## Change

Run one controlled A/B that holds the cosmic tree fixed and varies ONLY
the cosmos pin, then record the answer and file the follow-up. No file
in the tree is modified by this slice; the pin edit below is a scratch
edit that gets reverted.

1. **Noise floor first.** Build the tree and measure the machine before
   trusting any delta:

   ```
   bin/cosmic --make build
   o/bin/cosmic --make run _perf/gate.tl selfcheck o/perf/a.json o/perf/b.json
   ```

   Record the `perf-selfcheck:` verdict line and the per-scenario ± for
   `json_decode_large` and `codec_base64_roundtrip_64k`. If the
   self-check reports either of those two scenarios as varying by more
   than the bar, this machine cannot answer the question — stop, record
   that, and say so in the item; do not proceed to step 2 on a noisy
   box.

2. **A: the current pin.** With `3p/cosmos/cosmos_pin.tl` untouched:

   ```
   o/bin/cosmic --make run _perf/run.tl --out o/perf/pin-0824.json
   ```

3. **B: the pre-bump pin.** Edit `3p/cosmos/cosmos_pin.tl` in place to
   `version = "2026.08.21-07fc94a1c"` and
   `sha = "03e5286bce12d1080f00cdd1f2a72f634b6b0b7c0ce4e2287205d63221ef6f03"`
   (both taken from `git show ea71d799 -- 3p/cosmos/cosmos_pin.tl`),
   then:

   ```
   bin/cosmic --make fetch
   bin/cosmic --make build
   o/bin/cosmic --make run _perf/run.tl --out o/perf/pin-0821.json
   ```

   Run the FULL scenario set on both sides, with no `--only`:
   `_perf/compare.tl:140` marks a scenario present in the baseline and
   absent from the current run `missing`, and `:76` counts missing as a
   failure, so a filtered run cannot be compared against an unfiltered
   one.

4. **Compare, old as baseline:**

   ```
   o/bin/cosmic --make run _perf/gate.tl compare \
     o/perf/pin-0821.json o/perf/pin-0824.json o/perf/selfb.json
   ```

5. **Restore the pin** — `git checkout -- 3p/cosmos/cosmos_pin.tl`,
   then `bin/cosmic --make fetch && bin/cosmic --make build` — and
   confirm the tree is clean before recording anything.

6. **Record and hand over.** Write the `perf-selfcheck:` and
   `perf-compare:` verdict lines, and the two scenarios' before/after
   µs/op and ±, into this item's spec sidecar under a `## Result`
   heading (`gitboard spec <id> FILE`). Then take exactly one branch:

   - **Both deltas reproduce across the pin** (either scenario over the
     10% bar and not excused by the gate's A/A triage) — the cosmos
     build did regress them. File one item against the C repo:
     `gitboard new "<scenario>: +N% between cosmos 07fc94a1c and
     354c17e08" --repo whilp/cosmopolitan --spec-file F`, where F
     carries the two verdict lines, the two results files' numbers, and
     the bisect range `07fc94a1c..354c17e08` with the five commits in
     it. Then `gitboard block <this id> <new id>`.
   - **Neither reproduces** (the compare passes, or the gate triages
     both as noise) — the pin is exonerated and the deltas belong to
     the release runner, not to the code. File one item for the durable
     fix — the release gate cannot tell a layout shift from a
     regression for these two scenarios, and the answer is a decision
     record under `skills/decide`, not a quietly widened threshold —
     `gitboard new "release perf gate: a layout shift reads as a
     regression for json_decode_large and codec_base64_roundtrip_64k"
     --spec-file F`. Then dispatch `release.yml` ONCE with
     `perf_gate: false` to publish past the captured regression, which
     is what `release.yml:148-155` reserves that input for, and say in
     the item that it was dispatched and why.
   - **Exactly one reproduces** — do both of the above, each scoped to
     the scenario the evidence supports.

## Non-goals

- **No scenario or `check()` is weakened, renamed, or removed** — not
  `json_decode_large`, not `codec_base64_roundtrip_64k`, not their
  input sizes. The `optimize` skill's standing rule.
- **The gate's threshold is not changed in this slice**, and not in any
  slice without a decision record. Widening `--threshold` or adding
  either scenario to the gate's noise-excused set is exactly the
  "weaken it until it passes" move this item exists to avoid.
- **No product code and no pull request.** Nothing under `cosmic/`,
  `_cli/`, `_make/`, `_tool/` or `_perf/` is edited. `3p/cosmos/cosmos_pin.tl`
  is edited only as scratch and restored; this slice's `git status` at
  the end is clean.
- **No `o/perf/*.json` is committed** — the `optimize` skill's rule;
  the numbers go into the item's spec sidecar as prose, not as files in
  the tree.
- **The cosmos pin is not rolled back as a fix.** `2026.08.24-354c17e08`
  and later carry `cosmo.DecodeLua`, which `cosmic.literal` now uses by
  default (`ea71d799`); reverting the pin would break the tree. If the
  regression is real, it is fixed in whilp/cosmopolitan, not by pinning
  backwards here.

## Acceptance

Run from the cosmic repo root.

- `o/bin/cosmic --make run _perf/gate.tl selfcheck o/perf/a.json o/perf/b.json`
  ends with a `perf-selfcheck:` verdict line — quote it verbatim in the
  item's `## Result`.
- `o/bin/cosmic --make run _perf/gate.tl compare o/perf/pin-0821.json
  o/perf/pin-0824.json o/perf/selfb.json` ends with a
  `perf-compare: PASS` or `perf-compare: FAIL` line — quote it verbatim
  in the item's `## Result`, with the two scenarios' µs/op and ± from
  both sides.
- `git status --porcelain` → empty. The pin was restored and no
  results file was committed.
- `bin/cosmic --make ci` → `ci: PASS (5 stages)`. Nothing in the tree
  changed, so this is the proof that step 5 actually restored it.
- `o/bin/gitboard show <this id>` prints a `## Result` section carrying
  both verdict lines, and the follow-up item this slice filed appears
  in `o/bin/gitboard status`.

## Enablement

`none needed` for the measurement itself: `skills/optimize/SKILL.md`
carries the loop, `skills/optimize/measurement.md` the noise
discipline, and both gate commands are already in the harness.

Two enablement facts this slice depends on, both now true:

- The blocker `3ISWHWQT` landed as PR #1415 (main `90f0a744`), so
  `_perf/run.tl` type-checks under an older embedded env and the
  release lane's compare step can run again. Without it this slice
  could measure locally but the lane could never confirm the answer.
- The dual-run shape this slice needs — one tree, two cosmos pins —
  needs no new tooling: `bin/cosmic --make fetch` unpacks whatever
  `3p/cosmos/cosmos_pin.tl` names, into `o/3p/cosmos/`.

One friction to record when this slice ends, whichever branch it takes:
it produces no pull request, so it reaches `check` with `--pr` omitted
and its reviewer has only the item to read. That is the shape
`decompose.md` prescribes for a research slice, and it is the first one
on this board — say in the handover whether reviewing an evidence-only
item worked.
