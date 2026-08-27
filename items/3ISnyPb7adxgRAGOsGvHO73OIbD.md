The cold-build rule is remembered, not enforced, and `--make ci`
actively hides the failure it names. Two specs in a row have now
asserted the rule did not apply to them and been wrong.

The rule, as `3ISKgfS6` recorded it after its own bounce: a source
that needs the PATCHED checker fails build generation 1, which
compiles with the pinned release's embedded (unpatched) tl. `--make
ci` converges — it builds first and re-execs into what it built — so
it judges the change with the tree's own checker and passes. Only a
cold `--make build`, or CI's `build`/`repro` lanes, see it.

Observed 2026-08-26 on PR #1416 (item `3ISSFN5u`), run 32995853861,
job 98264755312:

```
cosmic: tree build failed; running pinned release
  .../releases/download/2026-08-15-c497c04/cosmic-lua
_cli/build/init_test.tl:73:14: error: cannot index key 'match' in
  variable 'lua' of type string | nil
build: FAIL (536 files)
```

`ci` was green on the same commit.

**Two things to fix, and they are separable.**

1. **The rule's scope is stated too narrowly.** `3ISKgfS6` writes it
   as "every `cosmic/**` source in a tl-patch slice must type-check
   under BOTH the pinned checker and the patched one". The file that
   failed here is `_cli/build/init_test.tl`, which is not under
   `cosmic/**`. Generation 1 compiles the WHOLE tree under the pin, so
   the rule is tree-wide. Wherever it is written down, it should say
   so.

2. **Nothing checks it before a PR is open.** The countermeasure
   worth weighing, strongest first: a local verb or flag that
   type-checks the tree under the PINNED checker specifically (the
   thing `--make ci` cannot do by construction, because converging is
   its whole point), so a slice can cite it in Acceptance; failing
   that, a documented Acceptance line — `--make clean && --make build`
   — that every patch-consuming slice carries, which is prose and
   will be forgotten again.

Related standing capture: `3IIm7ZyN`, filed for the same family after
PR #1405.

## Refinement findings (2026-08-27, claim-time measurement)

- The skew-guard shape (`_perf/skew_test.tl`, landed as 3ITdgu6f /
  PR #1427) does NOT generalize tree-wide as-is. Measured: a
  whole-tree sweep `COSMIC_COVERAGE=0 o/bootstrap/cosmic --check
  types $(git ls-files '*.tl' | grep -v testdata)` passes on today's
  tree in ~15s wall. But the bootstrap resolves `cosmic.*` from its
  EMBEDDED declarations (verified in 3ITdgu6f's spec: the two-arg
  literal.format probe fails under the 08-23 release binary from the
  repo root), while build generation 1 resolves tree modules against
  the TREE — so the sweep over-enforces: any PR adding a new public
  `cosmic.*` API plus a caller would false-fail the sweep while a
  cold build is green. Today the sweep passes only because the pin
  (2026-08-27-afad5b5) is hours behind HEAD.
- The sound mechanism therefore needs the pinned CHECKER (old tl +
  old patch set) with TREE module resolution — exactly generation 1's
  semantics. Open question for the next refine: whether `--check
  types` under the bootstrap can be pointed at the tree ahead of its
  embedded declarations (searcher/include-path behavior in the check
  verb), or whether the verb has to be a `--make` half-build that
  stops after generation 1's compile.
- Fix 1 (restate the scope tree-wide) has no in-tree home today:
  `grep -rn "pinned checker" docs skills AGENTS.md` finds only an
  unrelated paragraph in docs/design/make/resolution.md. The rule
  currently lives only in board item 3ISKgfS6's spec. Writing it into
  the tree (where patch-consuming sessions read) is part of any cut
  of this item.
