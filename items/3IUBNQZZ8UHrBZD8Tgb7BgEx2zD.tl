return {
  ["block_reason"] = {
    ["3IVF3HbVUGBgHw6ZKvy6PYhTXOg"] = "CORRECTED 2026-08-27 after PR #1463 was rejected. The old reason -- 'route 2 fixes the guard first and lands this unchanged as one PR' -- was false: that PR non-goaled the guard's BEHAVIOUR and changed only its prose, and a probe at its head (compare.format widened to (deltas, _title?: string), one gate.tl:143 call site) still gives 'wrong number of arguments (given 2, expects 1)' and test: FAIL. What actually blocks this item is that nothing yet owns changing the guard's behaviour; 3IVF3HbV's next refine must decide whether it absorbs that question or files it separately, and this edge re-points if it files",
  },
  ["blocked_by"] = "3IVF3HbVUGBgHw6ZKvy6PYhTXOg",
  ["builders"] = "0b13d2b4-bb26-5bc1-8635-407acd85452c e532d9f6-4b7d-5145-9534-7c6759ebc0d8",
  ["id"] = "3IUBNQZZ8UHrBZD8Tgb7BgEx2zD",
  ["parent"] = "3HyRcd9FVIczIYW5swnw2IXbnGA",
  ["phase"] = "plan",
  ["title"] = "codec compare rows are state-split: derive per-scenario noise floors from cross-window A/A history",
}
