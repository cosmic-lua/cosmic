return {
  ["block_reason"] = {
    ["3IWU4i0lsjlYkUehAG25BsSXCaH"] = "ordering, measured 2026-08-28: 3IWU4i0l is ready with a frozen spec anchored 'after the baseline retry and its identity check' and quoting _perf/gate.tl:305-316; this change DELETES that identity check from _perf/gate.tl (it moves into _perf/tiebreak.tl's baseline_side), so landing first turns its detail drift into value drift. Capacity runs the same way: this change takes the merged 490 to 488 (net -2), so on top of 3IWU4i0l's measured 493 it lands ~491, while the reverse order puts 3IWU4i0l over the 500-line cap. Not a merge conflict with #1485 or #1486: git merge-tree --write-tree --messages <proto> against each and against both is rc=0, and the whole _perf suite passes on plain origin/main + prototype, so no API either PR adds is used.",
  },
  ["blocked_by"] = "3IWU4i0lsjlYkUehAG25BsSXCaH",
  ["builders"] = "0b13d2b4-bb26-5bc1-8635-407acd85452c",
  ["claim"] = "0b13d2b4-bb26-5bc1-8635-407acd85452c",
  ["id"] = "3IYCkSTYUsu5wiVWo2g349bgj7B",
  ["parent"] = "3HyRcd9FVIczIYW5swnw2IXbnGA",
  ["phase"] = "check",
  ["pr"] = 1498,
  ["reviewer"] = "review-3IYCkSTY-20260829-055711-rev1",
  ["title"] = "perf gate: a disagreeing baseline pair has no tiebreak, so no formula can separate a false red from a masked regression",
}
