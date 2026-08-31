return {
  ["block_reason"] = {["3IYDxqM8wrkVrFp46Lx1q2Yt4Xq"] = "the spec cites a `### <class>` section of docs/design/casts.md and the per-site list docs/design/cast-sites.tsv. On origin/main casts.md carries only the 7 from-any classes (`git show origin/main:docs/design/casts.md | grep -c \"^###\"` -> 7, vs 21 on the branch) and cast-sites.tsv does not exist at all (`git ls-tree origin/main docs/design/` shows no such path). Both land with 3IYDxqM8 (PR #1489), so until it merges this spec references material a builder cannot read."},
  ["blocked_by"] = "3IYDxqM8wrkVrFp46Lx1q2Yt4Xq",
  ["builders"] = "work9c-agent-1",
  ["id"] = "3IYMJXQl4083ZgEbOrYrivWsZLq",
  ["parent"] = "3HyRcW05wBip6Wqcz145bUQBTyj",
  ["pr"] = 1585,
  ["resolution"] = "completed",
  ["speccers"] = "6c2afc8a-db7e-5772-90f9-63faf496a1d7",
  ["title"] = "casts: the 26 type-defeating test probes behind two named helpers — check.refuses, and one for absent surfaces",
  ["verdict"] = "accept",
  ["verdict_head"] = "d127c7386db207c2e258f4b206597d95edc15b58",
  ["verdict_spec"] = "08d81e1af012301bbf0ac4af6d78ee127ce97c766f36ea4f9af521656b57bd26",
}
