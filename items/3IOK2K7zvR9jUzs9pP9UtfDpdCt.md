G3 — close the **decoded-data shaping** class of `from any` casts: 61
of the tree's 192, the largest of the seven, measured 2026-08-25
against `d3e59de7` and mapped in `docs/design/casts.md`. A value comes
out of `json.decode`, `literal.parse`, a loaded config chunk or a
decoded report and is then reshaped or read field by field into a known
record, each read costing a cast. The files and their site counts:
_build/size.tl (1), _eval/score.tl (10), _eval/score_test.tl (12),
_eval/stage.tl (8), _eval/stage_test.tl (3), _make/pin_test.tl (2),
_perf/baseline.tl (1), _perf/compare.tl (1), _tool/coverage/report.tl
(2), _tool/doc/index_test.tl (1), cosmic/fetch/verbs_test.tl (1),
cosmic/json_test.tl (10), cosmic/literal_test.tl (7),
cosmic/teal_config_test.tl (2). Two mechanisms close it, and they split
the class: `json.decode_object` and `json.decode_array`
(`cosmic/json.tl:135` and `:155`) already type the outermost table, so
every `json.decode(s) as {string: any}` site is a call change with no
new API behind it; the field reads underneath need a decode that
validates into a declared record and hands it back typed, which does
not exist yet and is the part to design. Refinement should decide
whether those are one slice or two. The closure diff must lower the
affected rows in `_build/casts_baseline.tl` — run exactly the regen
command the gate prints and commit the result.

## Outcome, verified

All 61 sites are closed. Verified against `main` at `b5739e40`:

```
grep -c -- "-- cast: .*from any" _build/size.tl _eval/score.tl \
  _eval/score_test.tl _eval/stage.tl _eval/stage_test.tl _make/pin_test.tl \
  _perf/baseline.tl _perf/compare.tl _tool/coverage/report.tl \
  _tool/doc/index_test.tl cosmic/fetch/verbs_test.tl cosmic/json_test.tl \
  cosmic/literal_test.tl cosmic/teal_config_test.tl
```

reports `0` for all fourteen, and the same command without `.*from any`
also reports `0` — every site closed outright rather than being
re-justified with a truer reason, so all fourteen rows dropped out of
`_build/casts_baseline.tl`. Tree-wide the `from any` count now stands
at 55 of 259 total casts, down from 192 at intake.

The mechanism the class was missing was built first as the blocker
`3IOefXSz`: `cosmic/shape.tl` validates a decoded value against a Spec
and hands it back typed, with the target type coming from the caller's
annotation. It closed the non-test half (`3IOeg86u`) and the 21 test
sites whose test merely consumes decoded data (`3IPqUmoU`). The
remaining 17, whose subject IS the dynamic decode, took
`assert(v is T, msg)` instead (`3IPqVcwW`): a one-line guard that
checks at runtime what the cast only asserted, without a Spec naming
the shape the test is trying to discover.
