## Goal
G3 — an honest type layer, no escape hatches (parent `3HyRcW05`). The
closure-carry patch bought soundness at the price of a conservative
regression in the code AROUND a closure: defining any closure now
widens, in the ENCLOSING continuation, every narrow on a name assigned
anywhere in the file.

## Problem, measured
Measured 2026-08-27. Source:

```
local function pick(): string | integer
  return "x"
end
local v = pick()
v = pick()
if not (v is string) then return end
local cb = function(): integer return 1 end
print(cb())
print(v:upper())
```

The assignment precedes the guard, so the narrow at `v:upper()` is
sound, and `cb` neither reads nor assigns `v`. Stock tl accepts it; the
tree's checker rejects it with
`cannot index key 'upper' in variable 'v' of type string | integer`.

Reproduced by reverse-applying every `closure-*` entry's `replace` back
to its `find` in a scratch copy of `o/3p/tl/tl.lua` (10 entries, each
matching exactly once) and type-checking both copies under
`o/3p/cosmos/lua` via `tl.process`: stock clean, patched one error.
`o/bootstrap/cosmic --check types` and `o/bin/cosmic --check types`
agree with the patched copy — the pinned release
(`bin/cosmic.pin`, `2026-08-27-555873e`) already carries these entries,
so the pinned/tree pair does NOT isolate this regression and the
stock-vs-patched pair is the one that does.

## Change
The widen at a function boundary answers two different questions with
one scan, and they want different scopes:

- what the closure BODY may rely on — the closure may run at any later
  time, so the scan scope is the CHUNK ROOT. Correct as it stands, and
  `cosmic/teal_closure_test.tl` pins why.
- what the enclosing CONTINUATION after the definition may rely on —
  straight-line code, so only an assignment inside the closure's OWN
  body can invalidate a narrow there. This is what stock tl did at
  anonymous-function boundaries, and what the patch dropped.

`TypeChecker:widen_all_unions` (`o/3p/tl/tl.lua:10910-10941`) mutates
the enclosing scopes in place — `widen_in_scope`
(`o/3p/tl/tl.lua:8593-8645`) clears `scope.vars[name]`'s specialization
and `scope.narrows[name]` — so a chunk-root widen at the boundary
destroys narrows the continuation was entitled to keep.

Fix direction: at each function-boundary site, before the chunk-root
widen, snapshot the narrowed var records the chunk-root scan will drop
but an own-body scan would keep; after the closure's subtree is
checked, restore them into the same scope tables (keyed by the scope
TABLE, not its index).

The sites are the seven function-boundary entries in
`3p/tl/tl_patch/closure.tl` (`closure-anon-function`,
`closure-anon-macroexp`, `closure-fn-rvalue`, `closure-global-function`,
`closure-local-function`, `closure-local-macroexp`,
`closure-record-function`). `closure-assigned-scan`,
`closure-global-widen` and `closure-root` are not boundary sites and are
out of scope.

## Non-goals
Do not change what the closure BODY sees: the chunk-root scan and the
nearest-enclosing-body scope rejected in `closure.tl:14-17` both stay
as they are.

Do not touch `closure-global-widen`: a global's assignment universe is
every file, and scope 1 must stay always-assigned.

Do not touch the `["label"]` site — a narrow at a label must hold for
every goto path.

Do not memoize `assigned_anywhere`, and do not restructure its scan for
speed. Measured and refuted, 2026-08-27: wrapping `assigned_anywhere` in
`o/3p/tl/tl.lua` with an `os.clock()` accumulator and running
`tl.process` under `o/3p/cosmos/lua` over the 60 non-test modules of
`find cosmic _cli _make -name '*.tl' -not -name '*_test.tl' | sort |
head -60` gives 2925 calls costing 1.11 s of a 27.0 s run (4.1%). A
per-`(root, name)` memo hits 235 of 2925 calls (8%) and recovers 1.3
percentage points; a one-pass "names assigned in this chunk" set
recovers 2.3. Run-to-run spread on the same 60 files was ±2 s, so both
sit inside the noise floor — no memoization is justified on this
evidence, and every `.tl` in the tree is at or under the 500-line cap,
which bounds the scan a priori. Re-measure before reopening it.

Stay clear of the adjacent live items: `3IVQJa0b` (the closure rule also
fires at LOOP sites, undescribed and unpinned), `3IVSDpFq` (the
metatable is-dispatch rescue is inline-only), `3IVL4phw` / PR #1468
(trims `table_kinded` in `narrow.tl`).

## Acceptance
- `bin/cosmic --make fetch` succeeds — a patch DATA change is re-applied
  by fetch, and every entry's `find` must still match exactly once.
- The assertion is made against the DERIVED file, never the patch data:
  after `--make fetch`, `grep -c 'cosmic carried patch' o/3p/tl/tl.lua`
  is 23 today and must equal 23 plus one per new commented entry, and
  `grep -c '^  \["closure-' 3p/tl/tl_patch/closure.tl` is 10 today.
- Behaviour is proved with the two-checker technique: run each probe
  under `o/bootstrap/cosmic --check types` (pinned) and `o/bin/cosmic
  --check types` (tree) and compare verdicts. The probe above must go
  from rejected under both to rejected under pinned and CLEAN under
  tree; every source in `cosmic/teal_closure_test.tl` must keep the
  verdict it has today under BOTH.
- `bin/cosmic --make test cosmic/teal_closure_test.tl` passes, including
  the shapes pinned by `3IVL5DSr` — the soundness net this change must
  not tear.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _build/coldbuild_test.tl` passes.
- `git diff origin/main...HEAD --name-only` (THREE-dot; the two-dot form
  is a known recurring defect, `3IVHIoAx`) lists only
  `3p/tl/tl_patch/closure.tl` and `cosmic/teal_closure_test.tl`.

## Enablement
NOT at the ready bar. Blocked on `3IVL5DSr`, which pins the three
soundness shapes this change must not reintroduce; a scan split with no
net under it is the shape most likely to trade the regression back for
the hole.

Three decisions must be settled by a further refinement pass before
`move ready`:

1. Where each of the seven sites hangs the restore. `closure-fn-rvalue`
   is not a visitor `before`/`after` pair — it is inline inside the
   assignment handler (`3p/tl/tl_patch/closure.tl:99-112`), so it has no
   `after` hook and needs its own answer.
2. The exact restore operation. `widen_in_scope` has two exits — it
   either restores `specialized_from` in place or deletes
   `scope.vars[var]` outright, and at `n ~= top` it calls
   `add_var(nil, var, t, nil, "widen")` instead. The snapshot must
   capture enough to undo all three.
3. Whether narrows in INTERMEDIATE scopes (an upvalue narrowed in a
   parent function, seen from a nested closure) restore the same way, or
   whether the escaped-child case pinned by
   `test_an_escaped_child_does_not_keep_an_upvalue_narrow` forbids it.

Cold-build rule: this is a patch DATA change, so `o/3p/tl/tl.lua` is
re-derived by `--make fetch`, but generation 1 still compiles the whole
tree with the PINNED checker. A scan split only ACCEPTS more than today,
so no tree source can start failing generation 1 — no pin bump is needed
for the patch change itself. What must NOT land in the same PR is any
tree source that only type-checks under the new rule (dropping a cast
the regression forced, say): that stages behind a release and a
`bin/cosmic.pin` bump.
