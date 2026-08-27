The carried nil-union narrowing crosses closure boundaries and
survives later reassignment — an unsound acceptance, probed
2026-08-26 (research 3ISKgwfn) on the PRISTINE patched checker:

  local v = pick()            -- string | nil
  if v == nil then return end
  local function use(): string return v end
  v = pick()                  -- may be nil again
  print(use())

passes `--check types` (truthiness spelling too), yet use() can
return nil at runtime. Root cause: the patch's early-exit guard
narrowing does not register in scope.narrows, so
`widen_all_unions()` at function-definition sites never widens it —
unlike is-facts, which are correctly widened (and hence dropped) at
closures. G3 forbids exactly this shape of hole. The fix belongs with
the closure carry-through design (its enclosing-body
assigned_anywhere scan makes BOTH fact kinds sound and useful);
short of that, registering the patch's narrows in scope.narrows
restores stock soundness at the cost of re-losing the narrow at
closures. Either way a narrowing test must pin the reassignment case
as refused.

## Result (2026-08-27, closing diagnosis)

The stated root cause is wrong, measured against the patched checker
at main (instrumented `widen_all_unions` + probes): the early-exit
narrow IS registered in `scope.narrows` and IS widened at the
`local function` boundary — a probe indexing the closure's `v`
reports `got string | nil`, i.e. the widening worked. The probe's
acceptance is the checker's DOCUMENTED permissive nil-flow (an
unnarrowed `T | nil` passes a non-nil return/declared local; only an
index refuses — AGENTS.md, pinned in teal_narrowing_test.tl). So
"registering the patch's narrows" is a no-op that fixes nothing, and
the reassignment case will refuse exactly when strict nil-flow mode
(3IPXRRd2) lands — that item owns this hole. The closure carry-through
design this capture pointed at is 3ISSGDIN, refined and in flight
with a chunk-root scope (the enclosing-body scope proposed here is
unsound for escaped upvalue closures — counterexample recorded on
3ISSGDIN). Ended not-planned: nothing remains that another item does
not own.
