`_fuzz/driver_test.tl` is at 497 lines of the 500-line hard cap
(`_tool/lint.tl`), measured on the head of PR #1312. The next `_fuzz`
item that adds a test to it cannot, and will discover that as a lint
failure mid-implementation rather than as a spec decision.

This is not hypothetical: item 3ICDHHW7's spec measured the file at 471
and declared the cap "not near binding", having budgeted the change's
other lines but not the ~30 the new test it specified would itself add.
Written exactly as specified the file came out at 501 — one over — and
the implementing session had to tighten the new test's comment and
assertion messages to land under. That is the second `_fuzz` item in a
row whose spec measured a line count without including its own
addition (3ICDH3lW's Acceptance #6 warned about the same arithmetic and
told the session to re-measure rather than trust it).

Two things to decide, neither settled here:

- **The file.** `driver_test.tl` covers the whole driver surface —
  seeds and replay, the budget hook, isolation and the child timeout,
  shrinking's reported artifact. A split along one of those seams (the
  isolation/child-process tests are the most separable: they are the
  three that call `driver.run()` rather than `run_unisolated`, and they
  carry their own `skipped_by_a_sibling` helper) would give the next
  several items room. `_fuzz/driver.tl` at 465 has the same problem one
  item behind it.
- **The ready-bar rule.** A spec that quotes a measured line count and
  a placement decision derived from headroom should be required to
  state the count WITH its own change applied, not before it. Today the
  bar asks for measurement and gets it, but of the wrong number — which
  is worse than no number, because it reads as settled.

Whether that second half is an enablement item against the `work`
skill's `decompose.md` ready bar, or just this file's split, is the
triage judgment.
