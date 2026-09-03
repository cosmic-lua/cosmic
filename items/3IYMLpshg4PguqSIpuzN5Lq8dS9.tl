return {
  ["block_reason"] = {["3IYDxqM8wrkVrFp46Lx1q2Yt4Xq"] = "the spec cites a `### <class>` section of docs/design/casts.md and the per-site list docs/design/cast-sites.tsv. On origin/main casts.md carries only the 7 from-any classes (`git show origin/main:docs/design/casts.md | grep -c \"^###\"` -> 7, vs 21 on the branch) and cast-sites.tsv does not exist at all (`git ls-tree origin/main docs/design/` shows no such path). Both land with 3IYDxqM8 (PR #1489), so until it merges this spec references material a builder cannot read."},
  ["blocked_by"] = "3IYDxqM8wrkVrFp46Lx1q2Yt4Xq",
  ["builders"] = "orchestrate9-N5Lq_8dS9",
  ["claim"] = "orchestrate9-N5Lq_8dS9",
  ["id"] = "3IYMLpshg4PguqSIpuzN5Lq8dS9",
  ["parent"] = "3HyRcW05wBip6Wqcz145bUQBTyj",
  ["pr"] = 1649,
  ["speccers"] = "48a92156-b7f4-5273-b993-ba9f946ffb80",
  ["title"] = "tl: enum subtyping — a subset enum is a subtype, every enum is a string, and 11 cast sites wait on it",
}
