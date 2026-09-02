## Goal

G3 — an honest type layer. The `cosmic/fs/**` cut of the `cosmic/**`
`check.must` sweep (3IQfJ1tn): the four fs test/example files, small
enough to land as one diff and file-disjoint from every sibling child.

## Evidence

Census Method (`docs/design/nil-flow.md`, `## Method`) re-run
2026-09-02 at `5a36e7c9` under a strict binary that reproduced the
Method's proof-of-life; the `cosmic/fs/**` rows, with the producing
call each traces to:

```text
cosmic/fs/path_test.tl:323 (x2), :328 (x2), :338   operand of '..'
  -> ONE producer: line 319 `local cwd = fs.cwd()` (fs.cwd(): string | nil, string).
     fs.absolute_path returns a plain `string`; every flagged operand is `cwd`.
cosmic/fs/path_test.tl:210   argument 1   fs.basename(filepath)   loop var of fs.find_iter (line 209)
cosmic/fs/traps_test.tl:159  argument 1   fs.basename(p)          loop var of fs.find_iter (line 158)
cosmic/fs/walk_example.tl:87 argument 1   fs.basename(p)          loop var of fs.find_iter (line 86)
cosmic/fs/walk_test.tl:89    in assignment collected[#collected + 1] = p   loop var (line 88)
cosmic/fs/walk_test.tl:430   argument 1   fs.basename(p)          loop var of fs_find.find_iter (line 429)
```

10 rows, 4 files. The five loop-variable rows exist because
`cosmic/fs/find.tl:108` declares `FileIter.__call: function(self):
string | nil, {string}` and tl types a `for … in` variable from the
iterator's first return (probe: a `function(): string | nil` iterator
flags its variable at a `string` sink; a `function(): string` one does
not). Every file already imports `cosmic.check`. Headroom (`wc -l`):
path_test 422, walk_test 442, traps_test 230, walk_example 100.

## Change

- `cosmic/fs/path_test.tl:319` → `local cwd = check.must(fs.cwd())`
  (clears all five `..` rows).
- The five loop-variable sites: wrap the variable at its use —
  `fs.basename(check.must(p))`, `collected[#collected + 1] =
  check.must(p)`. No producing call exists to wrap; the loop body
  never sees the terminating nil, so `must` cannot throw there.

No other edit. Every assertion, and its count, is unchanged.

## Non-goals

- No file outside `cosmic/fs/**`; no library file (the `FileIter`
  declaration stays as is — it is a public API type and a separate
  decision).
- No checker change; no `docs/design/nil-flow.md` / `.tsv` edit; no
  committed strict checker.
- Do not change what a test asserts. Do not add a cast.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The Method's scan, filtered to this cut, reports **0**:
  `… | grep -E '^cosmic/fs/' | grep -E '_(test|example|benchmark)\.tl'`
- The scan's other shares are unmoved from the pull-time baseline
  (2026-09-02: `cosmic/**` test share 103 → 93 for this child alone;
  library 12; non-`cosmic/**` 0 / 11). Quote before/after in the PR.
- `git diff --name-only origin/main | grep -vE '^cosmic/fs/.*_(test|example|benchmark)\.tl$'` prints nothing.
