return {
  ["block_reason"] = {
    ["3IYPq8SxLNDcoulo9HNQESCYK2z"] = "the item measures \"13 of 15 rules documented\" against origin/main, and 3IYPq8Sx (PR #1491) changes both halves: it adds the doc-citation rule and documents it, taking docs/guides/lint.md from 13 to 14 `^## ` headings (`git show <ref>:docs/guides/lint.md | grep -c \"^## \"` gives 13 on origin/main, 14 on refs/pull/1491/head), and `git diff --name-only origin/main refs/pull/1491/head` lists docs/guides/lint.md. So the count to close is not 13-of-15 after #1491 lands, and the file the fix edits is a moving target. The items own spec already names 3IYPq8Sx in prose; this records it as an edge so `next` can see it.",
  },
  ["blocked_by"] = "3IYPq8SxLNDcoulo9HNQESCYK2z",
  ["id"] = "3IYTD6MmNRrraCeDgg8mEBxYKCA",
  ["parent"] = "3HyRcW05wBip6Wqcz145bUQBTyj",
  ["title"] = "docs/guides/lint.md claims to enumerate every rule the gate can fire and omits two of fifteen",
}
