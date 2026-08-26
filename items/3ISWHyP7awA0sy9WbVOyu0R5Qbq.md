## Goal

G9 — every release publishes, measured. `release.yml`'s perf gate has
refused to publish since 2026-08-24, and the two scenarios it flags are
unexplained. This item decides, by measurement, whether the two deltas
belong to the cosmos pin or to the release runner.

**Status: bounced from `do` back to `plan` on 2026-08-26.** The A/B this
spec asked for cannot be built. What the attempt measured is recorded
under `## Result` below and is not lost; `## Change` needs a new
experiment design before this is pullable again. The gap is named under
`## The gap to close`.

## Evidence

The gate's own report, from the 2026-08-25 release run (32818853162),
against baseline `2026-08-23-d71d7f1`, after the gate's retry AND its
A/A triage:

- `json_decode_large` 798.63µs -> 891.35µs (+11.6%, noise ±10.0%)
- `codec_base64_roundtrip_64k` 132.05µs -> 159.82µs (+21.0%, noise ±10.0%)
- 9 scenarios got faster (literal parse -97% among them).

`release.yml:156-188` measures the PREVIOUS release binary and the new
build in the SAME job on the SAME runner, then runs one A/A self-check
to triage, so "different runner" is not a free explanation.

Measured 2026-08-26 at cosmic `main` `ec794d44`, from each repo's root.

**Neither hot path has a source change behind it.** Both scenarios go
straight into cosmo C bindings — `_perf/bench/json_bench.tl:55-72` calls
`json.decode`, which `cosmic/json.tl` forwards to `cosmo.DecodeJson`;
`_perf/bench/micro_bench.tl:114-129` calls `codec.encode_base64` /
`decode_base64`, which `cosmic/codec.tl:37,83` forwards to
`cosmo.EncodeBase64` / `cosmo.DecodeBase64`. In the window the cosmos
pin moved exactly once, in `ea71d799` (2026-08-24, PR #1362):
`git show ea71d799 -- 3p/cosmos/cosmos_pin.tl` →
`2026.08.21-07fc94a1c` (sha `03e5286b…`) becomes
`2026.08.24-354c17e08` (sha `eae5513b…`). In whilp/cosmopolitan across
that exact range:

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

So the leading hypothesis remains **binary layout**: a new translation
unit shifted code with no algorithmic change anywhere.

## Result

Measured 2026-08-26 on the session container (`nproc` → 4), cosmic
`main` `ec794d44`, cosmos pin `2026.08.26-fe7c36c4c`, after
`bin/cosmic --make build` → `build: PASS (536 files, 1 binary)`.

**1. Full-suite A/A — the box is NOT quiet in suite context.**
`o/bin/cosmic --make run _perf/gate.tl selfcheck o/perf/a.json
o/perf/b.json` (2m26s) →
`perf-selfcheck: the scenarios flagged above vary by more than the bar
on noise alone; discount same-named perf-compare regressions`, with
`48 scenarios: 7 regression, 1 faster, 40 ok`. Among the seven the same
binary flagged against ITSELF:

- `json_decode_large` 1.21 ms -> 1.36 ms **+12.6%** (noise ±11.8%)
- also `tar_extract_tree` +48.5%, `fs_walk_tree` +21.1%,
  `teal_check_module` +19.2%, `literal_format_pin` +17.6%,
  `literal_parse_pin` +11.9%, `format_module_source` +10.2%
- `codec_base64_roundtrip_64k` 197.32 µs -> 201.29 µs +2.0% — **ok**

So in-suite, this box reproduces the release lane's `json_decode_large`
flag (+12.6% here vs +11.6% there) with no code change at all.

**2. Isolated A/A — the wake, not the scenario.** `measurement.md`'s
tie-breaker (`selfcheck … --only <name>`; note the flag must follow the
two path arguments, or `--make run` reads them as module names and dies
with `require o/perf/ja1.json: module not found`):

- `--only json_decode_large`, round 1: 1.14 ms -> 1.14 ms **+0.5%**,
  spread ±2.9% → `perf-selfcheck: nothing exceeded the bar`
- `--only json_decode_large`, round 2: 1.27 ms -> 1.23 ms **-3.1%** →
  `perf-selfcheck: nothing exceeded the bar`
- `--only codec_base64_roundtrip_64k`: 216.60 µs -> 209.58 µs
  **-3.2%**, spread ±3.0% → `perf-selfcheck: nothing exceeded the bar`

Within a call both scenarios are quiet (±3%). ACROSS calls
`json_decode_large` drifts 1.14 ms → 1.27 ms, about **11%** — the same
size as the release lane's flag — while base64 stays inside 3.5%.

**3. The A/B in `## Change` step 3 cannot be built.** With
`3p/cosmos/cosmos_pin.tl` set to `2026.08.21-07fc94a1c` /
`03e5286b…`, `bin/cosmic --make fetch` → `fetch: PASS (2 pins)`, and
then `bin/cosmic --make build` → `build: FAIL (536 files)` on:

```
cosmic/literal.tl:29:26: error: invalid key 'DecodeLua' in record 'cosmo' of type cosmo
cosmic/_literal_format.tl:302:23: error: unknown field literal
```

`ea71d799` moved `cosmic.literal` onto `cosmo.DecodeLua` in the SAME
commit that bumped the pin, and `DecodeLua` is added by `354c17e0` —
the very commit under suspicion. The tree at `main` therefore cannot be
built against the pre-bump cosmos, so "hold the cosmic tree fixed and
vary only the pin" is not an experiment that exists at this commit.
This spec's own `## Non-goals` said reverting the pin would break the
tree while `## Change` asked to do it: the contradiction is the bounce.

The pin was restored (`git checkout -- 3p/cosmos/cosmos_pin.tl`,
refetch, rebuild → `build: PASS`), and `git status --porcelain` is
empty.

## The gap to close

The next refinement has to pick ONE experiment that can actually run,
and state it. The candidates measured above leave open:

1. **A/B at an older cosmic commit.** Check the tree out at
   `ea71d799^` — before `cosmic.literal` took the `DecodeLua`
   dependency — and build THAT tree against both pins. Isolates
   `354c17e0` exactly. Costs a second worktree and a second full build;
   needs someone to confirm `ea71d799^` builds against
   `2026.08.24-354c17e08` as well as against `2026.08.21-07fc94a1c`.
2. **A/B across pins the tree can build.** `2026.08.24-354c17e08` (the
   first pin carrying `DecodeLua`) versus today's
   `2026.08.26-fe7c36c4c`. Buildable both ways, but it does NOT span
   the suspect commit, so it can only exonerate later pins, never
   `354c17e0`.
3. **Answer it in the release lane instead.** `3ISWHWQT` (PR #1415) is
   merged, so the compare step runs again; one `release.yml` dispatch
   re-measures both binaries on one release runner, which is the
   machine whose numbers the gate actually enforces.

Whichever is chosen, two things this attempt established should be
carried into it, and they point in opposite directions:

- `json_decode_large`'s flag is **not safely attributable to code**: a
  4-core container reproduces a +12.6% in-suite A/A swing and ~11%
  run-to-run drift in isolation, both at the size of the release lane's
  +11.6%. Any experiment that judges this scenario needs isolated,
  repeated measurement on both sides, not one suite pass.
- `codec_base64_roundtrip_64k`'s flag is **not explained by noise
  here**: it held inside 3.5% across every A/A, in suite and isolated.
  Its +21.0% is the one that still wants a cause, and no source in its
  path changed across the pin window.

Note for whoever refines this: the two scenarios may deserve to become
two items. They now have different evidence and probably different
answers, and keeping them in one slice is what made the single A/B
design look sufficient.

## Change

**Superseded — do not implement as written.** Step 3 below is
unbuildable at `main`; see `## Result` item 3 and `## The gap to close`.
Retained only so the next refinement can see what was tried.

1. Build, then `_perf/gate.tl selfcheck` for the noise floor; stop if
   either scenario flags against itself.
2. Measure the current pin into `o/perf/pin-0824.json`.
3. Swap `3p/cosmos/cosmos_pin.tl` to `2026.08.21-07fc94a1c`, refetch,
   rebuild, measure into `o/perf/pin-0821.json`. ← cannot build.
4. `_perf/gate.tl compare` old against new.
5. Restore the pin; confirm the tree is clean.
6. Record the verdict lines in this item and file the follow-up: a
   whilp/cosmopolitan item if the deltas reproduce across the pin, or a
   release-gate item plus one `perf_gate: false` dispatch if they do
   not.

## Non-goals

- **No scenario or `check()` is weakened, renamed, or removed** — not
  `json_decode_large`, not `codec_base64_roundtrip_64k`, not their
  input sizes. The `optimize` skill's standing rule.
- **The gate's threshold is not changed**, in this item or any other,
  without a decision record. Widening `--threshold` or adding either
  scenario to the noise-excused set is the "weaken it until it passes"
  move this item exists to avoid.
- **No product code and no pull request.** The deliverable is recorded
  evidence and the follow-up items.
- **No `o/perf/*.json` is committed.** The numbers live in this
  sidecar as prose.
- **The cosmos pin is not rolled back as a fix**, and — established
  above — cannot be even as an experiment at this commit. If the
  regression is real it is fixed in whilp/cosmopolitan.

## Acceptance

Superseded along with `## Change`; the next refinement writes these
against whichever experiment it picks. What held and should survive:

- `git status --porcelain` → empty at the end: any pin edit is scratch
  and restored.
- `bin/cosmic --make ci` → `ci: PASS (5 stages)`.
- Every gate invocation's verdict line (`perf-selfcheck:` /
  `perf-compare:`) quoted verbatim into this item's `## Result`, with
  the two scenarios' µs/op and ± from both sides.

## Enablement

`none needed` for the measurement itself: `skills/optimize/SKILL.md`
carries the loop and `skills/optimize/measurement.md` the noise
discipline — whose isolated-re-measurement tie-breaker is what turned
this attempt's in-suite `json_decode_large` flag into a ±3% reading and
is not optional for this scenario.

The blocker `3ISWHWQT` landed as PR #1415 (main `90f0a744`), so
`_perf/run.tl` type-checks under an older embedded env and the release
lane's compare step can run again — which is what makes candidate 3
above available.

Two frictions this attempt found, worth their own captures if they
recur:

- `--make run _perf/gate.tl selfcheck --only NAME A B` fails with
  `require A: module 'A' not found`; the flag must come AFTER the two
  path arguments. `measurement.md:85-92` shows it in the other order.
- A research slice reaches `check` with no PR, so its reviewer has only
  the item to read. This attempt never got that far, but the next one
  will.
