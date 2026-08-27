## Evidence

`cosmic/teal_narrowing_test.tl` is at 485 of the 500-line hard cap
(`_tool/lint.tl`), measured on PR #1439's head `d743c9bb`
(`wc -l cosmic/teal_narrowing_test.tl` → 485). It was 438 before that
PR; 3ISSFrCO's two tests took 47 of the 62 lines of headroom, leaving
15.

That file is where every carried `narrow-*` tl-patch entry pins its
behaviour, and the patch group still has queued items behind it —
3IPXRRd2 (strict nil-flow mode as a sixth patch group) among them.
The shortest existing test in the file is 18 lines
(`test_mixed_pack_keeps_n_integer`, lines 421-438) and the two just
added are 23 and 24. So the next narrowing item cannot add its test
and will discover that as a lint failure mid-implementation rather
than as a spec decision — the same shape 3IHFPLpb records for
`_fuzz/driver_test.tl`, on a different file and with a live queue
behind it.

Not settled here: where the split seam is. The file's tests group
readably by what they pin — the assert/decl rules, the exit-branch
rules (`break`/`goto`/`error`/`os.exit`), the or/and value-position
rules, and now the metatable is-dispatch — and any one of those is a
plausible `teal_narrowing_*_test.tl` sibling. Picking the seam, and
whether the split happens before or as part of the next narrowing
item, is the work.

Note this is NOT the ready-bar arithmetic failure 3IHFPLpb's second
half describes: 3ISSFrCO's spec did state the headroom (62) and that
its own two tests had to fit inside it, and they did. The file is
simply full.
