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
