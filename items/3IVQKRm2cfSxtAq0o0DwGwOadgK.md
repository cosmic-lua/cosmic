## Evidence

`closure-global-widen` landed as whilp/cosmic#1467. Its anchor is
inside `widen_all_unions` itself, not at the seven closure-boundary
call sites — so the rule reaches every caller of that function,
including the loop sites (`o/3p/tl/tl.lua:13173, 13241, 13262, 13317`
for `while`, `repeat`, `forin`, `fornum`), which pass their own node.

The consequence, measured across the merge:

```teal
global g: string | integer = "x"
if g is string then
  for _i = 1, 3 do print(g:upper()) end
end
```

before: `Type check passed`; after: `error: cannot index key 'upper'
in variable 'g' of type string | integer`.

**This is correct, and it is the same soundness argument** — a loop
body can call into another module that assigns `g`, so a narrow
carried into the loop is exactly as stale as one carried into a
closure. It errs conservative. Straight-line use is unaffected:
`if g is string then print(g:upper()) end` passes both before and
after, which keeps the common idiom working.

**What is missing is that nothing says so.** The entry's comment
explains the closure story only, and the three tests that landed with
it (`cosmic/teal_closure_test.tl`) pin the closure and named-function
boundaries plus the stdlib-shadowing guard. A reader hitting the loop
diagnostic finds no comment and no test explaining why it fires, and
the test file's own name points away from loops.

Found in review of #1467 and recorded rather than folded in, because
the PR was accepted and adding a behaviour class to a merged diff is
a different change.

## What this item should do

1. **A sentence in the entry's comment** in `3p/tl/tl_patch/closure.tl`
   naming the loop sites as reached, with the one-line reason (the
   loop body can call out, so the narrow is as stale there as in an
   escaped closure).
2. **A fourth test** pinning the loop case, and a companion pinning
   that straight-line use still carries — the second matters more,
   because it is the idiom a user would notice breaking, and nothing
   currently guards it.
3. **Decide where the loop tests live.** `teal_closure_test.tl` is
   named for closures; if loops join it, its header needs to say the
   file covers the widen rule rather than the closure boundary.
   `teal_narrowing_test.tl` is the alternative home. Either is fine;
   pick one and say why in the header.

## Non-goals

- **No behaviour change.** The loop widen is sound and stays. This
  item documents and tests what landed; it does not narrow or widen
  the rule.
- No change to the entry's `find`/`replace` beyond the comment text
  inside `replace` — and note that touching `replace` changes the
  patched bytes, so `--make fetch` must be re-run and the resulting
  `o/3p/tl/tl.lua` re-verified as deterministic.
- No new patch entry.
