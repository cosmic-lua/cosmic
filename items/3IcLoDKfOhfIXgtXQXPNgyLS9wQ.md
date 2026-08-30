## Change

`cosmic/format/init_test.tl` has no `test_*` functions at all: 425
lines whose entire body is top-level `assert_format(...)` /
`assert_format_fails(...)` / `assert_idempotent(...)` calls. It would
classify `empty` under `_tool/discover` and so satisfy the migration
container's exit test while defeating its point — its assertions run as
a bare chunk with no per-test identity, no continue-past-failure (the
first failed assert ends the file), and no `--filter` reachability.
**`empty` is not an acceptable terminal state for a file that is
manifestly a test**; these are rewritten as cases the runner can see.
Measured against origin/main 45f56e81, 2026-08-30.

**The grouping is settled: one `test_*` function per comment-delimited
block.** The file already carries the structure — every group of
assertions is introduced by a `-- Test <thing>` or `-- Bug N: <thing>`
header, and there are 53 such blocks (a header line whose predecessor
is not itself a comment line):

```
awk 'NR>=36{ if ($0 ~ /^-- / && prev !~ /^-- /) n++; prev=$0 } END {print n}' cosmic/format/init_test.tl
```
→ `53`

Each block becomes `local function test_<slug>()` wrapping its
statements, named from its own header (`-- Test repeat/until` →
`test_repeat_until`, `-- Bug 2: method call colon should NOT get space`
→ `test_bug2_method_call_colon_no_space`). The header comment stays
above the function. The three top-level `do ... end` blocks (lines 216,
225, 232) become functions directly — their `do`/`end` is replaced by
the function header and `end`, not nested inside one. No case is
self-called: the file is runner mode (D29).

**The file must also be SPLIT, and this is not optional.** Wrapping 53
blocks adds two lines each, projecting 425 + 2×53 = **531 lines**,
over the hard 500-line cap that `cosmic --check lint` enforces:

```
awk 'NR>=36{ if ($0 ~ /^-- / && prev !~ /^-- /) n++; prev=$0 } END {print 425 + 2*n}' cosmic/format/init_test.tl
```
→ `531`

Split on the seam the file already has — general formatting behaviour
versus numbered bug regressions. Measured: 29 blocks / 206 lines are
`-- Bug` blocks, 24 blocks / 184 lines are not.

- `cosmic/format/init_test.tl` keeps the 24 general blocks. Projected
  35 (preamble + helpers) + 184 + 2×24 = **267 lines**.
- `cosmic/format/regressions_test.tl` is new and takes the 29 `-- Bug`
  blocks. Projected 35 + 206 + 2×29 = **299 lines**.

Both are comfortably under the cap. `cosmic/format/` already holds
sibling test files (`types_test.tl`, `literal_format_test.tl`), so a
second one is the established shape.

**Duplicate only the helpers each file actually calls — not all three,
verbatim, unconditionally.** This corrects a bounce measured on this
item 2026-08-30: `assert_format_fails` is called exactly once in the
whole file (line 44, inside `-- Test syntax error rejection`, a
GENERAL block — it stays in `init_test.tl`, never moves to
`regressions_test.tl`):

```
$ grep -n "assert_format_fails(" cosmic/format/init_test.tl
17:local function assert_format_fails(input: string, msg: string, filename?: string)
44:assert_format_fails("if if if\n", "should reject syntax errors")
```

and none of the 29 `-- Bug` blocks call it:

```
$ awk '/^-- Bug/{p=1} /^-- Test/{p=0} p' cosmic/format/init_test.tl | grep -c "assert_format_fails("
0
```

So `cosmic/format/regressions_test.tl` duplicates only the two helpers
its own blocks call — `assert_format` and `assert_idempotent` (both
used inside the `-- Bug` blocks) — from lines 7-16 and 25-34 of the
original file. It does NOT duplicate `assert_format_fails`; that
helper (lines 17-24) stays solely in `cosmic/format/init_test.tl`,
which keeps calling it at its one call site. Position is the manifest:
a shared `cosmic/format/testhelp.tl` would be `cosmic.format.testhelp`
— public API — for test helpers used by only two files, so duplication
(of exactly what each file needs) is still the cheaper wrong; this is
the same precedent `cosmic/format/types_test.tl` already sets, which
duplicates only the one helper (`assert_format`) it needs rather than
all three from `init_test.tl`.

**Delete the trailing `print("All format tests passed!")`** (line 425).
Under runner mode it would fire at module load, before any case runs,
asserting something not yet true; the runner's own summary is what
reports. This is the same defect as item 3IcH4Snp, which names three
other files — this one instance rides along here because this item
rewrites the file wholesale; do not touch 3IcH4Snp's three
(`cosmic/fs/times_test.tl`, `cosmic/format/types_test.tl`,
`cosmic/format/literal_format_test.tl` — leave those alone).

**No other file in the tree needs this.** Swept 2026-08-30 at 45f56e81
for `*_test.tl` with zero `local function test_` definitions: the only
hits besides this file are fourteen `_eval/testdata/**` fixtures of 1-2
lines each, which are deliberate fixture inputs for the eval runner,
not tests. So this item closes the class.

## Non-goals

No assertion changes: every `assert_format`/`assert_format_fails`/`assert_idempotent`
call keeps its input, expected output and message byte-identical, and
the total assertion count must not move. No formatter behaviour
change, and no change to `cosmic/format/init.tl`, `rules.tl` or
`types.tl`. No change to `_tool/discover.tl`'s classification rules as
a way of dodging the question. No renames of `assert_format` or
`assert_idempotent` in either file, and no reference (silencing or
otherwise) to `assert_format_fails` in `regressions_test.tl` — it is
simply absent from that file, matching the precedent that a file
duplicates only what it calls. No reflow of assertion bodies beyond
the indent their new enclosing function requires.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `_tool/discover` classifies both files `runner`, and neither
  `legacy` nor `empty`.
- `grep -c 'local function test_' cosmic/format/init_test.tl` → `24`,
  and the same on `cosmic/format/regressions_test.tl` → `29`.
- No self-calls: `grep -c '^test_[A-Za-z0-9_]*()$'` → `0` in both.
- Both files are ≤500 lines (`wc -l`), which `--check lint` also gates.
- `grep -c 'local function assert_format_fails' cosmic/format/regressions_test.tl`
  → `0` (it must not be duplicated there).
- The assertion count is preserved: the sum of
  `grep -cE '^\s*assert_(format|format_fails|idempotent)\('` across the
  two files equals the count on `origin/main`'s single file.
- `bin/cosmic --make test cosmic/format/` passes and reports 53 test
  functions across the two files.
