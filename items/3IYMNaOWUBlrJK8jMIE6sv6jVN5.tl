return {
  ["block_reason"] = {["3IYDxqM8wrkVrFp46Lx1q2Yt4Xq"] = "the spec cites a `### <class>` section of docs/design/casts.md and the per-site list docs/design/cast-sites.tsv. On origin/main casts.md carries only the 7 from-any classes (`git show origin/main:docs/design/casts.md | grep -c \"^###\"` -> 7, vs 21 on the branch) and cast-sites.tsv does not exist at all (`git ls-tree origin/main docs/design/` shows no such path). Both land with 3IYDxqM8 (PR #1489), so until it merges this spec references material a builder cannot read."},
  ["blocked_by"] = "3IYDxqM8wrkVrFp46Lx1q2Yt4Xq",
  ["builders"] = "build-6sv6_jVN5-k1l2",
  ["claim"] = "build-6sv6_jVN5-k1l2",
  ["id"] = "3IYMNaOWUBlrJK8jMIE6sv6jVN5",
  ["parent"] = "3HyRcW05wBip6Wqcz145bUQBTyj",
  ["pr"] = 1663,
  ["reviewer"] = "review-6sv6_jVN5-v1",
  ["speccers"] = "617186a3-6ded-5f05-a74a-6054c4631945",
  ["title"] = "cosmopolitan: the 10 function-shape casts are overloaded bindings — split the annotations in definitions.lua",
}
