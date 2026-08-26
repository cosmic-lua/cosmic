## Goal

G3, under the tl-patch gaps container (3ISJI4Lg): the three remaining
checker gaps, enumerated and designed. A RESEARCH slice — the
deliverable is recorded evidence and filed follow-up slices, not code:
no product-tree diff, no PR. This is the sibling that sizes the work
the pack-n slice (3ISKgfS6, landed) deliberately left out.

## Evidence

Measured 2026-08-26 at main `8f34339e`, from the repo root.

- **(1) or-fallback residue.** Three casts in `_cli/build/init_test.tl`
  carry the reason `or fallback does not narrow` —
  `grep -n "or fallback" _cli/build/init_test.tl` → lines 72, 144,
  169, each the comment above a `(fs.read(out) or "") as string`-shaped
  line. The carried `narrow-or-fallback` patch entry already makes
  `x or fallback` the plain type when the fallback cannot be nil, and
  `""` cannot be nil — so either a shape escapes the patch (a
  multi-return call truncated by parentheses, value position vs
  if-position, both-union operands) or the reason is stale and the
  cast removable. Unknown which; that is the question.
- **(2) closure carry-through.** Narrowing is dropped at every closure
  boundary even for locals never reassigned after the guard. The
  workaround idiom is in the tree twice, each with a comment naming
  it: `cosmic/coverage/init.tl:104-106` ("Narrowing does not cross
  into a closure; these typed locals carry it") and the same
  guard-then-typed-local shape in `_tool/benchmark.tl`. The open
  design question: can the checker prove non-reassignment cheaply
  enough to carry narrowed facts into closures soundly?
- **(3) metatable<any> is-dispatch.** `cosmic/fs/types.tl:251` carries
  `-- cast: metatable<any> is a nominal the checker refuses
  is-dispatch on` — `is` against a map/record target refuses a
  `metatable<T>`-typed value with "can never be", though every
  metatable is a table at runtime.
- **The probe method has precedent.** The strict-nil census and the
  pack-n refinement both prototyped candidate patch entries by editing
  the `o/3p/tl/tl.lua` copy directly, probing with
  `o/bin/cosmic --check types <probe.tl>`, and reverting — commands
  and outputs recorded in the spec. Scratch edits to `o/` are
  build-output edits: nothing committed, `--make fetch` restores them.
- **Where follow-ups go.** Follow-up slices attach under 3ISJI4Lg
  (this item's parent), the way 3ISKgfS6 and this item do. The
  pack-n bounce established the cold-build rule a follow-up spec must
  carry: any `cosmic/**` source change that needs the NEW checker
  cannot land in the same slice as its patch entry (see 3ISKgfS6's
  "Wrong turn, recorded" and capture 3ISPGV8z).
- **The handover mechanics.** A research slice has no PR;
  `move ID check` refuses without one, so the handover uses
  `--force --why "research slice, no PR (3IFUskgH)"` — the gap is
  already captured as 3IFUskgH and the `--force` here is the
  documented workaround, not a new exception.

## Change

Three investigations, each ending in a decision recorded in THIS
item's spec (append a `## Findings` section) plus zero or more filed
captures. No product-tree file changes; scratch probes only.

1. **or-fallback**: reproduce each of the three
   `_cli/build/init_test.tl` sites as a minimal probe file; run
   `o/bin/cosmic --check types` on the probe with the cast removed;
   classify the escaping shape (or conclude the reason is stale).
   Decision to record: patch-extension (file a capture with the
   anchored find/replace sketch and probe transcript) or truer reason
   (file a capture to re-justify the three casts; editing them is not
   this slice's).
2. **closure carry-through**: locate where tl resets narrowing facts
   at function entry (`grep` the patched `o/3p/tl/tl.lua` for the
   scope/facts machinery the `narrow-nil-union` helpers hook);
   prototype the smallest sound rule on the scratch copy — carry a
   narrowed local into a closure when no assignment to it exists
   anywhere after the guard — and probe both a sound case and the
   unsound one (reassignment after closure creation must still
   refuse). Decision to record: feasible with an anchor (file the
   capture with the sketch and both probe transcripts) or not cheaply
   provable (record why; the typed-local idiom stays, and the two
   in-tree comments remain its documentation).
3. **metatable<any>**: find the `is` refusal ("can never be") in the
   scratch copy; probe whether accepting a table-kinded is-target over
   a `metatable<T>` value type-checks the `cosmic/fs/types.tl:251`
   site without weakening any refusal a test pins. Decision to
   record: patch capture or truer-reason capture, as in (1).

Each finding in `## Findings` states its command and output verbatim,
dated — the same evidence bar a ready spec's measurements carry.

## Non-goals

- **No product-tree diff and no patch entry lands here.** Every
  decided change is a filed capture under 3ISJI4Lg; scratch `o/`
  edits are reverted (or left for `--make fetch` to restore).
- **No edits to the three cast sites, the fs/types cast, or the two
  typed-local idioms** — follow-up slices own those.
- **No `3p/tl/tl_patch.tl` edit, no pin bump, no upstream issue.**
- The pack-n gap is closed (3ISKgfS6, landed) and out of scope.

## Acceptance

A research slice: the acceptance is the recorded findings, checkable
from the board alone.

- This item's spec carries a `## Findings` section with one dated,
  command-quoting entry per gap (three entries), each ending in an
  explicit decision line (`decision: patch capture <id>` /
  `decision: truer reason, capture <id>` / `decision: not cheaply
  provable, idiom stays`).
- `gitboard tree` shows every capture the decisions name attached
  under 3ISJI4Lg (zero unplaced).
- `git -C <repo> status --porcelain` clean at the end — no
  product-tree file modified.
- Handover: `move 3ISKgwfn check --force --why "research slice, no
  PR (3IFUskgH)"`; the reviewer re-runs the quoted probe commands per
  review.md's research clause, then `done` — no `land`, nothing to
  merge.

## Enablement

none needed. The probe method is established (pack-n refinement and
the strict-nil census), the follow-up parent exists (3ISJI4Lg), the
no-PR handover's `--force` is the documented 3IFUskgH workaround, and
every site this research reads is cited above at a line number
verified today.

## Findings

Recorded 2026-08-26 at main `8f34339e`; every probe under
`o/bin/cosmic --check types`, scratch tl edits reverted (a clean
re-fetch of `o/3p/tl` plus a bootstrap rebuild; `git status` clean).

1. **or-fallback: the reason is stale.** Both probe spellings of the
   three sites pass today — `local lua = (fs.read("x") or "")` then
   `lua:match(...)` → `Type check passed`; `local lua: string =
   fs.read("x") or ""` → `Type check passed` — and deleting all three
   casts and comments from `_cli/build/init_test.tl` itself passes
   `--check types` on the edited file (reverted after).
   decision: truer reason — the casts are removable; capture
   3ISSFN5u.
2. **closure carry-through: the premise splits in two.**
   - `is`-fact narrowing IS dropped at closures: `raw is
     function(any)` guarded, `raw(1)` inside a `local function` →
     `error: not a function: <any type>`. The reset is the node-less
     `widen_all_unions()` at the function-definition sites (~13073,
     ~13586, ~13619, ~13648); `widen_all_unions(node)` already spares
     names not `assigned_anywhere(name, node)`. Prototyped the crude
     variant (pass the closure's own node at ~13073 and
     local_function): the sound probe passes AND the reassign-after-
     closure probe passes — unsound, since only assignments inside
     the closure are seen. The sound scope is the nearest enclosing
     function body; scopes store no nodes (`begin_scope` → `{vars =
     {}}`), so the real patch needs a current-body stack.
     decision: patch capture 3ISSGDIN.
   - The carried NIL-guard narrowing already crosses closures — and
     survives reassignment: `if v == nil then return end`, closure
     returning `v: string`, then `v = pick()` → `Type check passed`
     on the PRISTINE checker (truthiness spelling too). That is an
     unsound acceptance, not a missing feature: the patch's narrows
     never register in `scope.narrows`, so the widen pass cannot see
     them. decision: patch capture 3ISSGm9B (flagged as the
     highest-value of the four — G3 forbids exactly this hole).
3. **metatable<any>: feasible, sketch validated.** Scratch allowance
   at the two "can never be" fact-eval sites (branch warning ~11510,
   error ~11607) accepting metatable-over-table-kinded targets:
   `getmetatable(x) is {string: any}` probe → passed;
   `cosmic/fs/types.tl` rewritten cast-free at :251 → `Type check
   passed` (reverted); negative probe `mt is integer` → still
   refused "can never be". decision: patch capture 3ISSFrCO, with
   the fs/types cast retire deferred per the cold-build rule.

Method note for the reviewer: the scratch loop was edit
`o/3p/tl/tl.lua` → `bin/cosmic --make build` → probe; restoring
required `rm -rf o/3p/tl && --make fetch` AND `rm o/bin/cosmic` (the
stale binary otherwise recompiles the tree with the scratch checker
and the build goes red on `cosmic/json.tl`/`cosmic/searcher.tl` —
observed, and itself a live demonstration of the crude variant's
unsoundness leaking into real inference).
