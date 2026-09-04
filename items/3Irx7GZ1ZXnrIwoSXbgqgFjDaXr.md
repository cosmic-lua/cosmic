## Goal

`gitboard brief builder <id>` on an item that already carries a
`request changes` verdict and an open `pr` (a "rework" hand-back)
emits the exact same fresh-pull brief as an untouched item — an empty
`<BOUNCE_CONTEXT>` placeholder, no worktree-reuse instructions, no
push-not-new-PR instructions. The orchestrator hand-assembles all
three every time: a "why this is a rework" section quoting the
reviewer's actual finding, instructions to reuse the item's existing
worktree/branch (confirm it's clean and at the pushed head, do not
branch fresh, do not discard the diff), and instructions to push a fix
rather than open a new PR.

## Evidence

Two independent occurrences across two `/work N --routine` passes:

**Earlier pass** (logged under `3Ir6CVpaqE...` / `NJCj_HQIX`): six
rework rounds in one session (2 on one item, 4 on another), each
requiring the orchestrator to hand-fetch the reviewer's PR comment via
the GitHub API, hand-write worktree-reuse instructions, and hand-write
push/no-new-PR instructions. Cost: roughly 15-20 minutes and 8-10 tool
calls of hand-assembly PER round — on the order of 90-120 minutes and
50-60 tool calls of pure orchestrator overhead in that one pass, all of
it mechanical.

**This pass** (`3IrjZESx.../GDeh_uJY2`, `zvR2_ujhh`'s rework): the
orchestrator hand-assembled `<BOUNCE_CONTEXT>` again and introduced a
real bug doing it: it pasted the reviewer's finding (which correctly
named `_work/gitfriction.tl`, where the code had moved mid-build) but
left the spec block pasted below it still carrying the stale
`_work/gitgraph.tl` reference from the item's ORIGINAL spec, unedited.
The builder had to notice the file-location mismatch itself
(`## build zvR2_ujhh rework` entry, same friction log) before it could
start.

**Root cause**: `_work/item.tl`'s `Item` record already carries
everything needed — `verdict` ("" | "accept" | "request changes"),
`pr` (the PR number under review), and the item's own branch (its id's
first 8 characters, per `_work/brief.tl`'s existing `BRANCH` fill) —
and `gitboard show` already prints all three. `_work/brief.tl`'s
`cmd_brief` (`cosmic/o/board/_work/brief.tl:167`) never branches on
them for the `builder` kind; it always fills the same
`brieftext.BUILDER` template regardless of whether the item is a fresh
pull or a rework. The reviewer's actual finding text, though, is NOT
stored on the item at all — it lives only on GitHub, as the PR's
review body/comments. `_work/gh.tl` currently has no call that reads
it (`slug`, `pull`, `checks`, `head_checks` — no reviews/comments
read); `_work/api.tl`'s generic cached-GET transport is what such a
call would be built on, the same way `gh.tl`'s existing calls are.

## Change

1. In `_work/gh.tl`, add a read for a PR's review comments — GitHub's
   `GET /repos/{owner}/{repo}/pulls/{number}/reviews` (each review
   carries `state`, `body`, `submitted_at`) — following the existing
   `pull`/`checks` calls' shape (through `_work/api.tl`'s cached GET,
   same error-string convention, `s`/`repo` args identical to
   `head_checks`).
2. In `_work/brief.tl`'s `cmd_brief`, when `kind == "builder"` and the
   item's own `it.verdict == "request changes"` and `it.pr ~= 0`:
   fetch that PR's reviews via the new call, select the MOST RECENT
   review carrying `state == "CHANGES_REQUESTED"` (matching what the
   orchestrator has hand-picked in both occurrences above — the
   latest round's finding, not every round's), and fill
   `<BOUNCE_CONTEXT>` with a templated section quoting its `body`
   verbatim, plus a worktree-reuse paragraph keyed off the item's
   branch (`it.id:sub(1, 8)`, matching the existing `BRANCH` fill) —
   confirm the worktree exists and is clean and at the pushed head,
   do not branch fresh, do not discard the diff — and a push/no-new-PR
   instruction. A read failure (no reviews found, no token, a network
   error) leaves `<BOUNCE_CONTEXT>` unfilled exactly as today, so the
   brief still emits and the verdict line still names it as a
   placeholder the caller must fill by hand — this is a strict
   improvement over today's always-empty case, never a new failure
   mode.
3. Add or extend `_work/brieftext.tl`'s `BUILDER` template (or a
   sibling constant filled only in the rework branch) with the
   `<BOUNCE_CONTEXT>` section shape and the worktree-reuse/push
   paragraph, following the same `<UPPER_SNAKE>` fill grammar
   `_work/brief.tl:94`'s `fill` already implements.
4. Tests in `_work/brief_test.tl`: a rework item (verdict set, pr set,
   a fixture review fetch) produces a filled `<BOUNCE_CONTEXT>`
   quoting the selected review's body and a filled worktree-reuse
   section; a fresh item (no verdict) is unaffected — the existing
   fresh-pull brief tests must still pass unchanged; a rework item
   with multiple CHANGES_REQUESTED reviews selects the most recent by
   `submitted_at`, not the first.

## Non-goals

Not `review`-kind briefs — `brieftext_review.tl` already mints a
per-round session label and reads CI state fresh each time
(`ci_refusal`); this item is builder-kind only. Not the separate,
already-filed `rNh1_b1Se` candidates (headroom/per-file-check/bounce-
diff/base-conflict sentences) — that item is resolved (PR #1697,
merged) and covers other `brief.tl` gaps, explicitly not this one.
Not changing how a review's verdict is recorded or what `gitboard
verdict` accepts — this only reads what already exists on GitHub, not
what the board itself stores. Not a review-comment READ for anything
other than filling `<BOUNCE_CONTEXT>` — no new write path, no new
`gh.tl` mutation (the board's GitHub access stays read-only, per
`_work/api.tl`'s own stated design).
