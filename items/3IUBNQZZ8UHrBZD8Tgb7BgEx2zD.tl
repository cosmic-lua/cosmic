return {
  ["block_reason"] = {
    ["3IVF3HbVUGBgHw6ZKvy6PYhTXOg"] = "SETTLED 2026-08-27 by 3IVF3HbV's refine (session 0b13d2b4): it ABSORBS the guard's behaviour rather than filing it out, so this edge stands and does not re-point. 3IVF3HbV scopes _perf/skew_test.tl's child --check types to a _perf-only --include-dir, which resolves _perf.* from the tree while cosmic.* still comes from the pin's /zip/.tl. Measured at 8269ff42 with compare.format widened to (deltas, _base?: pt.Results, _cur?: pt.Results) and all five call sites (gate.tl:143,199,250,290; run.tl:358) passing three arguments: bare gives five 'wrong number of arguments (given 3, expects 1)' at exit 1, while --include-dir <a dir holding only _perf> gives exit 0 over 30 files with zero errors -- and an invented cosmic.literal API used from a _perf file still fails under that same scope. So this item lands unchanged in ONE PR once 3IVF3HbV merges",
  },
  ["blocked_by"] = "3IVF3HbVUGBgHw6ZKvy6PYhTXOg",
  ["builders"] = "0b13d2b4-bb26-5bc1-8635-407acd85452c e532d9f6-4b7d-5145-9534-7c6759ebc0d8 0b13d2b4-bb26-5bc1-8635-407acd85452c/3IUBNQZZ",
  ["claim"] = "05f7c552-0c90-51cb-99b3-e018759c6ed5",
  ["id"] = "3IUBNQZZ8UHrBZD8Tgb7BgEx2zD",
  ["parent"] = "3HyRcd9FVIczIYW5swnw2IXbnGA",
  ["pr"] = 1485,
  ["resolution"] = "completed",
  ["title"] = "codec compare rows are state-split: derive per-scenario noise floors from cross-window A/A history",
  ["verdict"] = "accept",
  ["verdict_head"] = "37ea41cb5d3216403fb8508920e1c811502d15a1",
}
