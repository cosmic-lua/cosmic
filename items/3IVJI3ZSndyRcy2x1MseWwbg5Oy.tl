return {
  ["block_reason"] = {
    ["3IVF3HbVUGBgHw6ZKvy6PYhTXOg"] = "the fix needs _perf/baserun.tl, which exists only on PR #1480's branch and not on main (verified with git ls-tree against origin/main and the branch). Building this first would mean either stacking on an unmerged branch, which the skill forbids, or duplicating the helper. The dependency is also evidential: this item's Evidence rests on the resolution behaviour established under 3IVF3HbV, and that technique is not settled — its predecessor PR #1463 was rejected for a manifest that silently disabled the release perf gate, and the replacement #1480 is in check, unreviewed.",
  },
  ["blocked_by"] = "3IVF3HbVUGBgHw6ZKvy6PYhTXOg",
  ["builders"] = "05f7c552-0c90-51cb-99b3-e018759c6ed5/3IVJI3ZS",
  ["claim"] = "05f7c552-0c90-51cb-99b3-e018759c6ed5/3IVJI3ZS",
  ["id"] = "3IVJI3ZSndyRcy2x1MseWwbg5Oy",
  ["parent"] = "3HyRcd9FVIczIYW5swnw2IXbnGA",
  ["phase"] = "check",
  ["pr"] = 1488,
  ["reviewer"] = "0b13d2b4-bb26-5bc1-8635-407acd85452c",
  ["title"] = "release.yml's peers lane runs the tree's peer harness bare, so it measures the release's copies, not the tree's",
}
