return {
  ["block_reason"] = {
    ["3IUBNQZZ8UHrBZD8Tgb7BgEx2zD"] = "measured 2026-08-28: a prototype of this change committed on origin/main@40776231 conflicts with #1485 in _perf/gate.tl (git merge-tree --write-tree --messages <proto> origin/claude/3IUBNQZZ-compare-rows -> rc=1, CONFLICT (content): Merge conflict in _perf/gate.tl). Both of this change's insertion points sit immediately above a print(compare.format(deltas)) line #1485 rewrites to print_report(...), and neither can move: the restore needs deltas from the pass's compare_once and must run before the print, which is the record.",
    ["3IVLAF3ZGqRL59hrEAL5NRY48fr"] = "API dependency, measured 2026-08-28: the same_side guard is same_binary(opts.current, retry), the gate.tl helper #1486 adds over compare.same_binary. Without it the guard is identity_refusal(...) == nil, which #1486 measured to admit STAMPLESS pairs as same-binary; a pair naming no binary would turn this rule on with no control credit and restore every dismissal. Not a merge conflict at the insertion point the spec names: with the loudest_control export beside triage_many, git merge-tree --write-tree --messages <proto> origin/claude/3IVLAF3Z-stampless-identity-v2 -> rc=0 (beside load_results it is rc=1 in _perf/compare.tl).",
  },
  ["blocked_by"] = "3IUBNQZZ8UHrBZD8Tgb7BgEx2zD 3IVLAF3ZGqRL59hrEAL5NRY48fr",
  ["builders"] = "0b13d2b4-bb26-5bc1-8635-407acd85452c",
  ["claim"] = "0b13d2b4-bb26-5bc1-8635-407acd85452c",
  ["enable"] = "none: both fixes are direct edits to text the builder already owns -- restate the firing region in D35 and _perf/reproduce.tl from the measured sweep, and apply skills/decide amend form to D34; no new capability, fixture or gate is needed",
  ["id"] = "3IWU4i0lsjlYkUehAG25BsSXCaH",
  ["parent"] = "3HyRcd9FVIczIYW5swnw2IXbnGA",
  ["phase"] = "check",
  ["pr"] = 1496,
  ["title"] = "perf gate: a regression quiet on pass 2 gets two samples and no A/A control",
  ["verdict"] = "request changes",
  ["verdict_head"] = "a060b2105196a3e16a7390c87e2f6a45468942eb",
}
