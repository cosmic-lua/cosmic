return {
  ["block_reason"] = {
    ["3IUBNQZZ8UHrBZD8Tgb7BgEx2zD"] = "measured 2026-08-28: a prototype of this change committed on origin/main@40776231 conflicts with #1485 in _perf/gate.tl (git merge-tree --write-tree --messages <proto> origin/claude/3IUBNQZZ-compare-rows -> rc=1, CONFLICT (content): Merge conflict in _perf/gate.tl). Both of this change's insertion points sit immediately above a print(compare.format(deltas)) line #1485 rewrites to print_report(...), and neither can move: the restore needs deltas from the pass's compare_once and must run before the print, which is the record.",
  },
  ["blocked_by"] = "3IUBNQZZ8UHrBZD8Tgb7BgEx2zD",
  ["claim"] = "0b13d2b4-bb26-5bc1-8635-407acd85452c",
  ["id"] = "3IWU4i0lsjlYkUehAG25BsSXCaH",
  ["parent"] = "3HyRcd9FVIczIYW5swnw2IXbnGA",
  ["phase"] = "plan",
  ["title"] = "perf gate: a regression quiet on pass 2 gets two samples and no A/A control",
}
