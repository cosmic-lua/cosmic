return {
  ["block_reason"] = {["3IYDxqM8wrkVrFp46Lx1q2Yt4Xq"] = "the spec cites a `### <class>` section of docs/design/casts.md and the per-site list docs/design/cast-sites.tsv. On origin/main casts.md carries only the 7 from-any classes (`git show origin/main:docs/design/casts.md | grep -c \"^###\"` -> 7, vs 21 on the branch) and cast-sites.tsv does not exist at all (`git ls-tree origin/main docs/design/` shows no such path). Both land with 3IYDxqM8 (PR #1489), so until it merges this spec references material a builder cannot read."},
  ["blocked_by"] = "3IYDxqM8wrkVrFp46Lx1q2Yt4Xq",
  ["builders"] = "wave4-2-0hVX",
  ["claim"] = "wave4-2-0hVX",
  ["id"] = "3IYMJwleEM9gBhpvVDF0hVX9EMj",
  ["parent"] = "3HyRcW05wBip6Wqcz145bUQBTyj",
  ["pr"] = 1605,
  ["speccers"] = "b69eb093-c2d4-5f3a-b5dd-826817f161b7",
  ["title"] = "casts: the 22 userdata-boundary sites down to one per handle type — declare each method table's self",
  ["verdict"] = "accept",
  ["verdict_head"] = "d90d95ce03d2541ae533c41246ec5ad9b7f27bc3",
  ["verdict_spec"] = "d6a5963fb885eb41efc1f365e8c0798c60120f3fcfc1f91d91d2c97c73c1df67",
}
