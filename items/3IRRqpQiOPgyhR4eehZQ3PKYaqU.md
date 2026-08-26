Three specs in the G3 casts thread prescribed checker-facing shapes the
checker then refused, and only the specs whose refinement APPLIED the
shape caught it before implementation. Evidence, all 2026-08-26:
3IQQf63I's Q5 found mid-implementation (a bounce) that two
`cosmic/sqlite/extras.tl` casts were not `from any` at all — pcall slot
2 is typed from `TxFn`, and `is string` is refused there. 3IQRDRwW's
spec prescribed `is TlResult` at `cosmic/_teal_engine.tl:248` (refused:
pcall slot 2 is tl's nominal `Result`, "can never be a TlResult") and a
`local ok, err = xpcall(...)` destructure in `cmd/cosmic/main.tl`
(refused: "did not produce an initial value" — tl types xpcall's extra
returns from the protected function, which was why the original code
used `table.pack`). Both were caught at refinement only because the
refiner applied the diff and ran `--check types` per file; the ready-bar
lint cannot see the difference. The gap: decompose.md's "measured, not
inferred" covers greps and line counts but not the checker's verdict on
a prescribed shape. Proposed rule for the ready bar (docs first, lint
later if it recurs): a spec whose Change prescribes a shape addressed to
the type checker — an `is` guard, a cast removal, a signature or
destructure change — states that the shape was applied and passed
`o/bin/cosmic --check types <file>` during refinement, the way measured
claims carry their command. A pcall/xpcall slot is the recurring trap:
its static type comes from the callee's declaration, not from `any`, so
"guard it with is" specs written from the census's `from any` reasons
are wrong exactly when the original cast's reason was wrong.
