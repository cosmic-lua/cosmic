## Evidence

Two agents in two runs read the orchestrator's checkout instead of
their own worktree: a builder `Read /home/user/cosmic/cosmic/fetch/init.tl`
(run 1, zbl9_M8VS, call 28) and a reviewer grepped `/home/user/cosmic`
for `safe_href`, found nothing (that checkout sat at `96afd807`, twelve
merges behind `origin/main`), and briefly concluded the PR's doc claim
was false before its fresh worktree showed `cosmic/url.tl:408`. The
orchestrator's checkout is where `o/board` lives and is never advanced
during a pass, so it is stale whenever it matters. The builder brief
says "Work exclusively inside that directory"
(`_work/brieftext.tl:21-24`); the review brief says "from your own
fresh checkout — never reuse another agent's worktree" (:238-240).
Neither names the checkout that contains the board worktree, which is
the one path every agent can see in every command the brief quotes
(`cd /home/user/cosmic/o/board`).

## Change

`_work/brieftext.tl` (after the split the builder-brief item performs,
or in both files if it landed first): one sentence in the builder's
"Where to work" and in the reviewer's checkout paragraph — "The
checkout that holds the board worktree (`<board dir>/..`) is the
orchestrator's and is stale by construction; never read, grep or build
in it. Your worktree is the only tree." `brief` fills `<board dir>`
from `--dir`.

`_work/brief_test.tl`: pin the sentence and the filled path.

## Non-goals

No sandboxing; prose only.
