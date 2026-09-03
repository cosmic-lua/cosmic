return {
  ["block_reason"] = {["3IYDxqM8wrkVrFp46Lx1q2Yt4Xq"] = "the spec cites a `### <class>` section of docs/design/casts.md and the per-site list docs/design/cast-sites.tsv. On origin/main casts.md carries only the 7 from-any classes (`git show origin/main:docs/design/casts.md | grep -c \"^###\"` -> 7, vs 21 on the branch) and cast-sites.tsv does not exist at all (`git ls-tree origin/main docs/design/` shows no such path). Both land with 3IYDxqM8 (PR #1489), so until it merges this spec references material a builder cannot read."},
  ["blocked_by"] = "3IYDxqM8wrkVrFp46Lx1q2Yt4Xq",
  ["builders"] = "peek-1 build-ke6b_yr5h-c3d4",
  ["claim"] = "build-ke6b_yr5h-c3d4",
  ["id"] = "3IYMQz3o1PNwTlNbMUbke6byr5h",
  ["parent"] = "3HyRcW05wBip6Wqcz145bUQBTyj",
  ["pr"] = 1664,
  ["reviewer"] = "review-ke6b_yr5h-v1",
  ["speccers"] = "e277faa5-ee02-55c9-8d7e-4d688b76f501 617186a3-6ded-5f05-a74a-6054c4631945",
  ["title"] = "G3 wording: the measured cast floor is 23, so decide whether zero as-casts stays literal",
}
