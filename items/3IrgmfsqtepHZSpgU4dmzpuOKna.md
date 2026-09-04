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

**Corroborated 2026-09-04, review-F6zo_pi1N-07d7b9b9**: a second,
independent reviewer this same pass also hit the `gh`-CLI-absence
friction, and found a third gap: `mcp__github__pull_request_read`'s
`get_status` method returned `"state":"pending","total_count":0` even
after the PR's checks had completed and it was merged — this repo runs
CI as GitHub Actions check-runs, not legacy commit statuses, so
`get_status` is structurally the wrong endpoint here. One extra tool
call (`get_check_runs`) was needed to get the real signal both times.

Measured 2026-09-04: `_work/brieftext_review.tl` is 191 lines, well
under the 500-line cap — room for the additions below.

## Change

`_work/brieftext_review.tl`'s `REVIEW` template, immediately after
"Fetch the PR diff and description yourself...verify independently."
(the paragraph beginning at line 23): add three sentences —

1. Naming the GitHub access path: this environment has no `gh` CLI;
   use the GitHub MCP tools (`ToolSearch` for `mcp__github__*` if not
   already loaded).
2. Naming the correct CI-status method: use
   `mcp__github__pull_request_read`'s `get_check_runs`, not
   `get_status` — this repo's CI is GitHub Actions check-runs, and
   `get_status` reads the legacy commit-status API, which this repo
   does not populate.
3. Naming the board-branch diff-scope caveat: `board`'s orphan-branch
   history mixes concurrent items' commits between any two shas, so a
   range diff (`git diff <base>..HEAD`) over-reports; use
   `git show --stat <single-commit-sha>` (or the PR's own file list
   via the GitHub API) to see one PR's actual scope.

`RESEARCH_REVIEW`'s template is unaffected — it has no PR/diff to
fetch or CI to check.

`_work/brief_test.tl` (or wherever brief-fill pins live): a `find` on
the filled `REVIEW` template confirms all three new sentences appear.

## Non-goals

No change to the fill grammar or to `BUILDER`/other templates — this
is three sentences in the `REVIEW` template's existing fetch paragraph.
