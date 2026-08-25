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
