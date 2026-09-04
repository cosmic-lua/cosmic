## Evidence

`friction: 2026-09-04 work9` (this pass), review-fmFu_8dce-07d7b9b9's
own report: getting CI status cost one wasted `gh pr view` call (`gh`
is not installed in this environment; exit 127) before falling back to
the GitHub MCP tools, which needed a `ToolSearch` round-trip since they
weren't pre-loaded. Separately, a plain `git diff <base-sha>..HEAD` to
check the PR's scope over-reported changed files, because the `board`
orphan branch's history between a PR's base sha and the current tip
includes unrelated items landed by other concurrent sessions — a range
diff on this branch shape picks those up too; the reviewer spent ~3
extra tool calls before switching to `git show --stat <single-commit>`,
the correct way to see one PR's actual file scope here.

Measured 2026-09-04: `_work/brieftext_review.tl` is 191 lines, well
under the 500-line cap — room for two short additions.

## Change

`_work/brieftext_review.tl`'s `REVIEW` template, immediately after
"Fetch the PR diff and description yourself...verify independently."
(the paragraph beginning at line 23): add two sentences —

1. Naming the GitHub access path: this environment has no `gh` CLI;
   use the GitHub MCP tools (`ToolSearch` for `mcp__github__*` if not
   already loaded).
2. Naming the board-branch diff-scope caveat: `board`'s orphan-branch
   history mixes concurrent items' commits between any two shas, so a
   range diff (`git diff <base>..HEAD`) over-reports; use
   `git show --stat <single-commit-sha>` (or the PR's own file list
   via the GitHub API) to see one PR's actual scope.

`RESEARCH_REVIEW`'s template is unaffected — it has no PR/diff to
fetch.

`_work/brief_test.tl` (or wherever brief-fill pins live): a `find` on
the filled `REVIEW` template confirms both new sentences appear.

## Non-goals

No change to the fill grammar or to `BUILDER`/other templates — this
is two sentences in the `REVIEW` template's existing fetch paragraph.
