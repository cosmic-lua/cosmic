return {
  ["block_reason"] = {
    ["3IYPq8SxLNDcoulo9HNQESCYK2z"] = "two ways, both verified. (1) the fix changes the recognizer in _cli/citations.tl, which 3IYPq8Sx (PR #1491) rewrites — `git diff --name-only origin/main refs/pull/1491/head` lists _cli/citations.tl and _cli/citations_test.tl, so building this first means resolving against a moving file. (2) the spec cites docs/design/casts.md:55-56 as the one tree exemplar, and that paragraph survives only on main: `git show <ref>:docs/design/casts.md | grep -c \"cosmic/json.tl:155\"` gives 1 on origin/main, 0 on PR #1491 (which converts it) and 0 on PR #1489 (which deletes it wholesale). Either merge strands the evidence. The recognizer defect itself is real on main and survives both; only the exemplar and the file baseline need re-measuring after #1491 lands.",
  },
  ["blocked_by"] = "3IYPq8SxLNDcoulo9HNQESCYK2z",
  ["id"] = "3IYT8Bpmz8LMVcejPeJ5Kd8PC2Z",
  ["parent"] = "3HyRcW05wBip6Wqcz145bUQBTyj",
  ["title"] = "the doc-citation lint pairs backticks per line, so a citation in a code span that wraps a line break is never checked",
}
