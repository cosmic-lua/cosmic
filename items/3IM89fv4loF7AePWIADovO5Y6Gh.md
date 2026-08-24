## Goal
G6 — the defining paths, ratcheted (this item's parent is the G6
container). `--check fmt` is a defining path: `--make ci` formats every
tracked source, so `format_module_source` is toolchain cost paid per
file, per gate run, by every contributor and every CI lane. Split out of
3IK8EOci during its 2026-08-24 refinement, which took only the
token-copy hypothesis so each diff carries one hypothesis.

**The hypothesis is no longer unproven.** This refinement built it and
measured it (numbers below), so what follows is a verified change to
transcribe, not a question to answer. The honest headline: a small,
deterministic allocation win and no measurable wall-clock win.

## Change
One file: `cosmic/format/init.tl`. Measured 2026-08-24 at `d1dff351`
(`wc -l cosmic/format/init.tl` = **383**, so **117 lines of headroom**
under the 500-line cap; the prototype landed at 398, and Acceptance
bounds it).

The emit pass appends to one `out: {string}` accumulator at 12 sites
(`grep -c "out\[#out + 1\]" cosmic/format/init.tl` = **12**, at lines
182, 184, 257, 268, 283, 295, 297, 299, 301, 305, 308, 315), one
fragment per token, per space, per indent run and per newline — so a
~2160-token module pushes several thousand entries into a single growing
table before the final `table.concat`. **Buffer a line and concat it
once**, so `out` grows with lines rather than with fragments.

In `format`'s emit loop (`for _, line in ipairs(lines) do`, line 253):

- Declare the reused buffer immediately before that loop, beside
  `continues_type`/`type_depth`:

      local buf: {string} = {}
      local bn = 0

  One table for the whole function, reused across lines — allocating a
  fresh `{}` per line would trade one kind of table churn for another.
- Reset the count, not the table, as the first statement inside the loop
  body, after the existing blank-gap `out[#out + 1] = "\n"` at line 257:
  `bn = 0`. Stale entries past `bn` are never read because the concat is
  bounded (below).
- Rewrite the **nine** in-line append sites — lines 268, 283, 295, 297,
  299, 301, 305, 308 and 315 — from `out[#out + 1] = X` to the two-line
  form `bn = bn + 1` / `buf[bn] = X`, preserving indentation and the
  right-hand side exactly.
- Immediately after the line-terminating `buf[bn] = "\n"` (line 315
  today) and before `indent = math.max(0, indent + post_change)`, append
  the finished line:

      out[#out + 1] = table.concat(buf, "", 1, bn)

  The explicit `1, bn` bounds are what make reuse-without-clearing
  correct; `table.concat(buf)` would read stale entries from a longer
  previous line.
- **The three remaining `out` sites do not move.** Lines 182 and 184 are
  the shebang, emitted before the loop; line 257 is the blank-line gap
  emitted *between* lines. Neither is part of a line's text.

Nothing else changes: no rule, no `Item` field, no pass order, no
signature.

**Verified, not proposed.** This exact shape was built and gated during
refinement on 2026-08-24 at `d1dff351`: `bin/cosmic --make ci` ended
`ci: PASS`, `wc -l` was 398, the diff was +24/−9, and the two grep counts
below came out at 4 and 9.

**What it buys, measured.** Three runs of the scenario against the
prototype build, against a baseline run of the same command on the
unmodified tree:

| | `alloc_kb` | wall |
|---|---|---|
| baseline | 1478.08 | 7.52 ms ± 4.9% |
| prototype | 1432.96, 1432.98, 1432.98 | 7.05 ms ± 5.9%, 8.63 ms ± 31.0%, 8.11 ms ± 15.3% |

— i.e. **−45.12 KB, −3.05%** of the scenario's allocation, deterministic
across runs, and **no wall-clock result**: this host's spread on this
scenario reached 31%, which swamps any change of this size. Do not sell
this as a speed-up; `alloc_kb` is the claim, and Acceptance gates only
that. Commands:

    o/bin/cosmic --make run _perf/run.tl --only format --out o/perf/format-X.json
    o/bin/cosmic -e 'local j,f=require("cosmic.json"),require("cosmic.fs") for _,s in ipairs(j.decode(f.read("o/perf/format-X.json")).results) do if s.name=="format_module_source" then print(s.alloc_kb) end end'

## Non-goals
- **The output bytes do not move.** Not one file in the tree may format
  differently. Not a reformat, not a rule fix, not a new style. The
  `fmt` stage of `--make ci` is what enforces this over every tracked
  source, and it is Acceptance 1.
- **Do not clear or reallocate `buf` per line** (`buf = {}`, a
  `for i = 1, #buf do buf[i] = nil end` loop, or `table.move`). The
  reuse plus the bounded concat IS the change; clearing gives the
  allocation back.
- **Do not fold in the other emit hypotheses.** `mark_type_params`'
  per-line rescan is board item **3IM89sc3**; the token-copy removal in
  `build_items` is **3IK8EOci** (PR #1353, in review as this was
  written). One commit, one hypothesis (`skills/optimize`).
- **Do not touch `cosmic/format/rules.tl`, `cosmic/format/types.tl`, or
  `3p/tl/**`**, and do not change the order in which `tl.lex`,
  `tl.parse_program` and `build_items` run.
- Do not rename, delete, or weaken `format_module_source` or its `check`
  (`_perf/bench/format_bench.tl:58-79`, which pins `ok = true` and
  idempotence); do not commit `o/perf/*.json`.
- Do not add an `as` cast. The prototype needed none, so a cast in this
  diff means the shape drifted from what was verified.

## Acceptance
Run from the repo root; the build under test is what this change
produces (`bin/cosmic --make build`, then `o/bin/cosmic`). Every command
writes only under `o/`.

1. `bin/cosmic --make ci` ends with `ci: PASS`. This is the correctness
   proof for a formatter change: the `fmt` stage re-formats every
   tracked source with the NEW formatter and fails on any byte
   difference, and the gate converges (it re-execs into what the tree
   built), so the formatter is checked under its own formatting.
2. `o/bin/cosmic --make test cosmic/format/init_test.tl
   cosmic/format/types_test.tl cosmic/format/literal_format_test.tl`
   ends with `test: PASS`.
3. The accumulator sites moved, and only the three named ones stayed:

   ```sh
   grep -c 'out\[#out + 1\]' cosmic/format/init.tl   # 4  (12 today)
   grep -c 'buf\[bn\]' cosmic/format/init.tl         # 9  (0 today)
   ```

   4 is the shebang pair, the blank-gap newline, and the one new
   per-line `table.concat` append.
4. Allocation, the direct measure of this hypothesis. Measure the
   pre-change build first, then the post-change build, and take the
   difference — a DELTA rather than an absolute ceiling, because
   #1353 moves the baseline if it lands first:

   Baseline first, **before editing `cosmic/format/init.tl`** — this is
   the `skills/optimize` loop's own first step, so nothing extra is
   asked of the session:

   ```sh
   bin/cosmic --make build
   o/bin/cosmic --make run _perf/run.tl --only format --out o/perf/format-before.json
   ```

   Then, with the change in place:

   ```sh
   bin/cosmic --make build
   o/bin/cosmic --make run _perf/run.tl --only format --out o/perf/format-after.json
   o/bin/cosmic -e 'local j,f=require("cosmic.json"),require("cosmic.fs") local function kb(p) for _,s in ipairs(j.decode(f.read(p)).results) do if s.name=="format_module_source" then return s.alloc_kb end end end print(kb("o/perf/format-before.json") - kb("o/perf/format-after.json"))'
   ```

   (A reviewer who wants to reproduce takes the baseline from a second
   worktree at the PR's merge-base; no command here touches the
   committed tree.)

   The last line prints **≥ 40** (45.12 measured during refinement).
   `alloc_kb` is deterministic, not noise-bound — a run that does not
   move it did not remove the fragments. Quote both absolute numbers in
   the PR description.
5. `wc -l cosmic/format/init.tl` is ≤ 410 (383 today; the prototype was
   398). A number above that means the transcription grew something the
   verified shape did not.

**Wall clock is explicitly not an acceptance criterion here** — the
measured spread swamps a change this size. Run the full compare gate
(`o/bin/cosmic --make run _perf/gate.tl compare ...`) and quote the
`format_module_source` row, but only a row that REGRESSES past its
noise bar blocks: re-measure in isolation (`skills/optimize/measurement.md`,
"when a flag survives triage") and revert if it reproduces.

## Enablement
none needed. The change was built and gated during this refinement pass,
so the shape is transcription rather than judgment, and every predicted
wrong turn already has a command that catches it: output drift fails the
`fmt` stage over every tracked source; a concat left unbounded
(`table.concat(buf)`) fails the same stage the first time a short line
follows a long one; a buffer cleared per line fails the `≥ 40` delta in
Acceptance 4; a mis-transcribed site fails the grep counts in
Acceptance 3.

One overlap to know rather than to wait on: **#1353 (item 3IK8EOci)
edits the same file** and was in review when this was written. Its hunk
is `build_items` (lines 94-120); this one's is the emit loop (lines
253-330), so the two are disjoint and no `blocked_by` edge is recorded.
Rebase on `main` before measuring, and note that Acceptance 4 is a
delta precisely so it stays valid whichever lands first.
