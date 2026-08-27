## Goal

G3 — an honest type layer: an `is`-fact narrow survives into a
closure exactly when nothing in the FILE can invalidate it, and the
two closure soundness holes stock tl carries at anonymous-function
boundaries close with the same change.

## Evidence (re-probed 2026-08-27 at this refinement, patched checker
at main, `sha256sum o/3p/tl/tl.lua` → `77a25cb9…`)

- **The gap**: `v: string | integer` guarded by
  `if not (v is string) then return end`, then
  `local function use(): string return v end` → REFUSED
  ("got string | integer, expected string") — is-facts are widened at
  every function boundary however safe they are (probe7; probe3 is
  the inside-if variant, same result).
- **A real stock unsoundness the fix closes** (probe8): the same
  guard with an ANONYMOUS closure (`local use = function(): string
  return v end`) followed by `v = 2` PASSES today — stock's
  `["function"]` visitor widens with the closure's OWN node
  (tl.lua:13836), so a later enclosing-scope reassignment never
  widens. `use()` returns 2 as string at runtime.
- **3ISSGm9B's diagnosis is wrong, measured**: the early-exit
  nil-narrow IS registered and IS widened at closures — an
  instrumented `widen_all_unions` shows `narrows[2]: v` widened at
  the `local function` site, and a probe indexing the closure's `v`
  reports `got string | nil`. probe1/probe2's acceptance is the
  checker's DOCUMENTED permissive nil-flow (an unnarrowed `T | nil`
  passes a non-nil return; AGENTS.md, pinned in
  teal_narrowing_test.tl), owned by 3IPXRRd2's strict mode — not a
  registration hole. That item is ended with this pass.
- **The capture's "nearest enclosing body" scope is unsound**,
  constructed counterexample: chunk-level `v` narrowed INSIDE
  `parent()` (upvalue guard), `child` closure keeps the narrow (v
  never assigned in parent's body), `parent` returns `child`, chunk
  then runs `v = 2` and calls the escaped child → stale narrow. The
  sound, simple scope is the CHUNK ROOT: scan the whole file. Name-
  level matching over-approximates bindings (an unrelated same-named
  assignment widens spuriously) — conservative, never unsound.
- **The label site must keep widening everything**: narrows at a
  `::label::` must hold for every goto path, including one from
  before the guard with no assignment anywhere — so
  tl.lua:13158's node-less call is deliberately untouched.

## Change

New patch group file `3p/tl/tl_patch/closure.tl` (narrow.tl is 393
lines — 107 headroom, too little for ~130 lines of entries), entries
named `closure-*`, all `file = "tl.lua"`, no `tl.tl` twin (checker
logic). Anchors verified exact-once against the fetched tl.lua:

1. `closure-root` — after `assert(ast.kind == "statements")` (one
   site, tl.lua:15149), set `self.chunk_body = ast` before
   `recurse_node(self, ast, visit_node, visit_type)`.
2. Seven widen call sites switch to
   `self:widen_all_unions(self.chunk_body)` — nil falls back to
   stock widen-all, so any entrance that skips `closure-root` keeps
   stock behavior:
   - the function-rvalue assignment site (tl.lua:13076,
     `if rval.typename == "function" then`),
   - `local_function` / `local_macroexp` / `global_function` /
     `record_function` `before` (13589/13622/13651/13695, today
     node-less),
   - `["function"]` / `["macroexp"]` `before` (13836/13871, today
     passing the closure's OWN node — the probe8 unsoundness).
   The `["label"]` site keeps its node-less widen-all.

Tests in a NEW `cosmic/teal_closure_test.tl`
(teal_narrowing_test.tl is 485/500 and teal_test.tl 493/500 — no
room), house shape (fs.write to TEST_TMPDIR, teal.check_file,
self-called tests):
- the guarded chunk-level name, never assigned, used in a named
  closure → checks (the coverage-idiom win; refused today);
- the same with `v = pick()` anywhere after the closure → refused
  (assignment-anywhere widens);
- probe8's anonymous shape with reassignment → refused (the stock
  hole closes);
- the escaped-child upvalue counterexample above → refused (the
  scope decision pinned).

## Non-goals

No change to `["label"]`'s widen-all, to loop/while/if widening
(they pass their own nodes for a different question), to
`assigned_anywhere` itself, or to `widen_in_scope`. No nil-flow
strictness change: `T | nil` stays permissive outside indexes
(3IPXRRd2). No retiring of the coverage/benchmark idiom sites in
this slice (cold-build rule: source depending on the new rule waits
for a pin that carries it). Existing patch entries stay
byte-identical; `_make/patch.tl` untouched.

## Acceptance

- `bin/cosmic --make fetch` ends `fetch: PASS` (all entries apply
  exact-once).
- `bin/cosmic --make ci` ends `ci: PASS`.
- `o/bin/cosmic --make test cosmic/teal_closure_test.tl` passes with
  the four tests above.
- `wc -l 3p/tl/tl_patch/closure.tl` ≤ 500; `wc -l
  cosmic/teal_closure_test.tl` ≤ 500.
- `grep -c '^  \["closure-' 3p/tl/tl_patch/closure.tl` → 8.

## Enablement

none needed — the split (3ITo9Inv) landed, the pin carries the
directory mechanism, and every anchor was verified against the
fetched checker in this pass.

## Implementation notes (2026-08-27, recorded at build)

Two discoveries during the build, both in the landed diff:

- **A ninth entry, `closure-assigned-scan`, is REQUIRED for
  soundness**: stock `assigned_anywhere` aggregates children with
  `ipairs`, and an else-block's children table starts at a nil hole
  (no condition at xs[1]), so every assignment inside an else branch
  — and inside a declaration's rvalue (same hole at the missing
  decltuple) — was invisible to the scan. `_tool/coverage/report.tl`'s
  format_ranges (assignments in an else) is the tree's own witness:
  without the fix the chunk-scan keeps its `first` narrow and the
  file refuses. Fixed with `pairs` (order is irrelevant to a
  boolean-or).
- **One tree fix**: `cosmic/json.tl` compared metatables with `==`
  behind a `typed any` marker local; the carried declaration narrow
  now keeps the constructor's specific `metatable<{any}>` and the
  comparison refuses as incomparable. Identity comparison via
  `rawequal` says what the code meant and checks under both the
  pinned and the patched checker (cold-build rule respected).
  `_tool/coverage/report.tl` needed nothing once the scan was fixed.

Also filed from this build: 3IU1dR9x (a red gen-2 leaves a poisoned
o/bin/cosmic and wedges every later run's gen-1 — escaped here with
`rm o/bin/cosmic`).
