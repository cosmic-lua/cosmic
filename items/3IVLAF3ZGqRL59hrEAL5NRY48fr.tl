return {
  ["block_reason"] = {
    ["3IVF3HbVUGBgHw6ZKvy6PYhTXOg"] = "measured at pull, not predicted: Change step 3 reaches step 1's new compare.same_binary key from _perf/gate.tl, and _perf/skew_test.tl type-checks _perf sources under the pinned bootstrap, whose embedded /zip/.tl/_perf/compare.tl (byte-identical to origin/main) has no such key — so ci FAILs with 'invalid key same_binary in record compare'. No pin lag to wait out. Verified the dependency directly: with only #1480's rewritten skew_test.tl swapped onto the branch, ci: PASS (5 stages), 936/936. Work is preserved on claude/3IVLAF3Z-stampless-identity @ b346ca66, no PR opened.",
  },
  ["blocked_by"] = "3IVF3HbVUGBgHw6ZKvy6PYhTXOg",
  ["builders"] = "0b13d2b4-bb26-5bc1-8635-407acd85452c",
  ["id"] = "3IVLAF3ZGqRL59hrEAL5NRY48fr",
  ["parent"] = "3HyRcd9FVIczIYW5swnw2IXbnGA",
  ["phase"] = "ready",
  ["title"] = "perf gate: stampless files pass identity refusals and join the same-binary noise controls",
}
