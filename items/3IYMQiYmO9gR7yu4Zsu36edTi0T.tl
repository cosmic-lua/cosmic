return {
  ["block_reason"] = {["3IYDxqM8wrkVrFp46Lx1q2Yt4Xq"] = "the spec cites a `### <class>` section of docs/design/casts.md and the per-site list docs/design/cast-sites.tsv. On origin/main casts.md carries only the 7 from-any classes (`git show origin/main:docs/design/casts.md | grep -c \"^###\"` -> 7, vs 21 on the branch) and cast-sites.tsv does not exist at all (`git ls-tree origin/main docs/design/` shows no such path). Both land with 3IYDxqM8 (PR #1489), so until it merges this spec references material a builder cannot read."},
  ["blocked_by"] = "3IYDxqM8wrkVrFp46Lx1q2Yt4Xq",
  ["builders"] = "decompose-36ed_Ti0T",
  ["id"] = "3IYMQiYmO9gR7yu4Zsu36edTi0T",
  ["parent"] = "3HyRcW05wBip6Wqcz145bUQBTyj",
  ["resolution"] = "completed",
  ["speccers"] = "617186a3-6ded-5f05-a74a-6054c4631945",
  ["title"] = "casts: the 32-site tail — six classes under 8 sites each, cut along the here/upstream line",
}
