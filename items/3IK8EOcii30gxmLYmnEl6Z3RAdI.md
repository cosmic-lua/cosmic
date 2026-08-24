## Goal
G6 — the defining paths, ratcheted (this item's parent is the G6
container). `--check fmt` is a defining path: `--make ci` formats every
tracked source, so `format_module_source` is toolchain wall clock paid
per file, per gate run, by every contributor and every CI lane.

Measured 2026-08-24 on this tree (`9bcb0f7d`), binary built from it:
`format_module_source` is **7.12 ms/op, 1478 KB allocated per op**,
spread ±4.7% (`o/bin/cosmic --make run _perf/run.tl --only format --out
o/perf/format.json`, then reading the scenario's `wall_ns`/`alloc_kb`).
The emit pass is the cosmic-owned half: on a 2161-token module built the
way the scenario builds its source, `tl.lex` is 2.04 ms, `tl.lex` +
`tl.parse_program` is 3.94 ms, and `cosmic.format.format` is 8.10 ms —
so **51% of the time is this repo's code after the parser returns**
(medians of 200 iterations, `os.clock`; scouting numbers, the harness
decides accept/reject). The remaining 49% is tl's lexer and a parse that
exists only to gate syntax errors — 3p/toolchain territory, out of
scope. Imports (never duplicates) whilp/cosmic#1102, "the formatter
allocates ~100x its input".

## Change
One hypothesis: **the formatter copies the token stream it already
owns**. `build_items` (`cosmic/format/init.tl:94-120`) allocates a fresh
`Item` table per token — `{y, x, tk, kind}` — for every one of the
module's tokens. Stop copying: annotate the lexer's tokens in place and
put the token tables themselves into the item list.

Measured cost of the copy, same probe: 2161 tokens cost **385 KB** to
copy into `Item` tables, against 2007 KB net allocation for the whole
`format` call on that source (`collectgarbage("count")` deltas around
the copy loop and around `format.format`).

In `cosmic/format/init.tl` (`wc -l` 383 today, 117 lines of headroom):

- `record Item is rules.Item` (line 28) already declares only the two
  fields the formatter adds — `_newlines`, `_tight_before` — over the
  `y`/`x`/`tk`/`kind` interface. `tl.Token` (generated,
  `o/_types/types_gen/tl.d.tl:22-28`) carries exactly `x`, `y`, `tk`,
  `kind`, `comments`, so a token satisfies that interface as it stands.
  In `build_items`, replace the per-token table constructor with the
  token itself: `items[#items + 1] = token as Item`, carrying a
  `-- cast: the lexer's tokens are the formatter's after parse; Item
  adds fields, it does not reshape them` justification.
- Keep everything else in `build_items` as it is: the `$EOF$` skip, and
  the comment items, which are built from `token.comments` entries
  (`{string: any}`, four casts today) and have no table of their own to
  reuse.
- Nothing else changes. The two fields the emit pass writes
  (`item._newlines` at lines 209 and 324, `item._tight_before` in
  `mark_type_params` at line 57) then land on the token tables, which is
  safe by ORDER, not by convention: `tl.parse_program` runs at line 152
  and `build_items` at line 170, so the parser has already read the
  stream before the formatter writes to it, and `tokens` is a local that
  leaves `format` only through the items list.

**Ratchets this diff moves.** `cosmic/format/init.tl` is at 8 casts in
`_build/casts_baseline.tl:63`, and this adds one. When
`_build/casts_test.tl` fails on it, run the command that gate names —
`bin/cosmic --make run _build/casts.tl --baseline` — commit the
regenerated baseline, and justify the +1 in the PR description. Do not
weaken the gate any other way.

## Non-goals
- **The other two hypotheses in this item's original research note stay
  out of this diff.** (b) buffering a line and `table.concat`-ing it
  once instead of appending to `out` at 12 sites
  (`grep -c "out\[#out + 1\]" cosmic/format/init.tl` is 12), and (c)
  folding `mark_type_params`' per-line rescan (line 36, called at line
  271) into the single emit walk. Each is its own hypothesis with its
  own measurement; one commit, one hypothesis (`skills/optimize`).
  File them as board items rather than folding them in.
- **The output bytes do not move.** Not one file in the tree may format
  differently. Not a reformat, not a rule fix, not a new style.
- **Do not touch `3p/tl/**`, `tl.lex`, or `tl.parse_program`**, or the
  order they run in.
- **Do not change the `Item` interface in `cosmic/format/types.tl:28`**
  or any signature in `cosmic/format/rules.tl` — the rules module is
  typed against that interface and both files are shared with the type
  marking passes.
- Do not rename, delete, or weaken `format_module_source` or its
  `check` (`_perf/bench/format_bench.tl:58-79`, which pins `ok = true`
  and idempotence); do not commit `o/perf/*.json`.

## Acceptance
Run from the repo root; the build under test is what this change
produces (`bin/cosmic --make build`, then `o/bin/cosmic`).

1. `bin/cosmic --make ci` ends with `ci: PASS`. This is the correctness
   proof for a formatter change: the `fmt` stage re-formats all 516
   tracked sources with the NEW formatter and fails on any byte
   difference, and the gate converges (it re-execs into what the tree
   built), so the formatter is checked under its own formatting.
2. `o/bin/cosmic --make test cosmic/format/init_test.tl
   cosmic/format/types_test.tl cosmic/format/literal_format_test.tl`
   ends with `test: PASS`.
3. Allocation, the direct measure of this hypothesis — these two lines,
   verbatim, from the repo root (they write only under `o/`):

   ```sh
   o/bin/cosmic --make run _perf/run.tl --only format --out o/perf/format-after.json
   o/bin/cosmic -e 'local j,f=require("cosmic.json"),require("cosmic.fs") for _,s in ipairs(j.decode(f.read("o/perf/format-after.json")).results) do if s.name=="format_module_source" then print(s.alloc_kb) end end'
   ```

   The second prints **≤ 1300** (1478.08 on this tree today, so a drop
   of at least 12%). `alloc_kb` is deterministic, not noise-bound — a
   run that does not move it did not remove the copy.
4. `wc -l cosmic/format/init.tl` is ≤ 500 (383 today; this change should
   shrink it).
5. Full-suite performance, per `skills/optimize`: baseline the
   pre-change build into `o/perf/baseline.json`, run the current build
   into `o/perf/current.json`, and
   `o/bin/cosmic --make run _perf/gate.tl compare o/perf/baseline.json
   o/perf/current.json o/perf/selfb.json` ends with
   `perf-compare: PASS`. Quote the `format_module_source` row
   (before/after, with its ± spread) in the PR description. A host whose
   spreads swamp the wall-clock delta does not block the change —
   criterion 3 is the one that must hold — but a `format_module_source`
   row that REGRESSES past its noise bar does: re-measure in isolation
   (`measurement.md`, "when a flag survives triage") and revert if it
   reproduces.

## Enablement
none needed. Each predicted wrong turn already has a command that
catches it: mutating tokens the parser still needs is ruled out by the
line ordering stated in Change and would fail `--make ci`; output drift
fails the `fmt` stage over all 516 files; a copy that was not actually
removed fails the `alloc_kb` bound in Acceptance 3; the cast ratchet
names its own regen command. The APIs involved are typed
(`cosmic/format/types.tl`'s `Item` interface, the generated
`tl.Token`), and the conventions are in AGENTS.md.
