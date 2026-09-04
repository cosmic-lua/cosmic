# friction: 2026-09-04 work9 (/work 9 --routine)

## orchestrator
- goal: bootstrap gitboard worktree/binary for this session (no prior worktree existed).
  actually happened: `git worktree add o/board board` failed with "invalid reference: board" — local repo had no local `board` ref, needed `git fetch origin board` first, then `git worktree add o/board origin/board -b board`. Cost: one extra fetch + retry, ~10s.
  contributed: skill bootstrap snippet (`git worktree add o/board board`) assumes `board` already exists as a local ref, which is false on a fresh clone/session with no prior board worktree.
  improvement: bootstrap doc could show the fetch+create form directly (or gitboard could detect and fall back to origin/board) — doc-level fix, cheap. Candidate for filing.
- sync result: `lane release.yml is failure` reported at sync time. Noting for triage/context; not necessarily actionable by this pass.
- goal: claim c5wU_p1n9's research handover (pull + `take --result`) as the orchestrator, since the recommendation was already fully drafted by a prior cycle and only needed applying/handover.
  actually happened: I ran `take c5wU_p1n9` and `take c5wU_p1n9 --result` with no `--session`, so gitboard recorded the "claim" field as my bare orchestrator session id (env-derived). Later minting a distinct review session (`--session review-c5wU_p1n9-3`) only set the item's separate "reviewer" field, not "claim". When I then tried `take` on four unrelated, file-disjoint build items under my default session, all four were REFUSED with "already holds 3IosEPKw — one claim per worker". Cost: 4 failed take calls + investigation (grep gittake.tl/action.tl, ~6 tool calls, a few minutes) before retrying with explicit `--session build-<handle>` on each, which succeeded immediately.
  contributed: `gitboard help orchestrate`'s "Claim first, then spawn... with a distinct minted session name per agent" states the rule, but doesn't warn that omitting `--session` on a take binds the claim to the orchestrator's own bare session id, which then blocks ALL further takes under that session — not just a second take on the same item, since gitboard applies one-claim-per-worker across the whole board, keyed on whatever the caller passed as session (or defaulted to). `help take`'s option text for `--session` ("Omit to derive it from the environment") reads as a convenience default, not a warning that omitting it is a footgun for an orchestrator that must remain unlocked to keep issuing further claims.
  improvement: doc-level fix — `gitboard help orchestrate` or `help take` should say explicitly: the orchestrator itself must NEVER take without an explicit `--session`, because its own bare session is a single global claim slot. A gate-level fix would be a `take` warning/refusal when the caller's session looks like a bare CLAUDE_CODE_SESSION_ID with no role prefix, but that's heuristic and probably not worth it; the doc fix is cheap and sufficient. Candidate for filing.
- goal: fill `<WORKTREE>`/`<BOUNCE_CONTEXT>` placeholders per `gitboard brief builder ID`'s closing "fill ..." line before dispatching each builder agent.
  actually happened: the closing verdict line for `cOu8_PnMv` names a spurious survivor `<N>` and for `RxN2_253n` a spurious `<REVIEW_SESSION>` — neither is a real unfilled placeholder in the template; both are literal `<N>`/`<REVIEW_SESSION>` substrings quoted inside the item's own verbatim spec prose (`with no (D<N>) reference`, `the <REVIEW_SESSION> placeholder goes away`), caught by the same `<%u[%u_]*>` regex the fill function uses to detect real placeholders. Cost: a few minutes double-checking the two briefs by hand (grep) to confirm nothing needed filling.
  contributed: `_work/brief.tl`'s survivor-detection scans the WHOLE filled text (including the verbatim spec body) for the placeholder pattern, with no way to distinguish a real template placeholder from prose that happens to look like one — worse for board-tooling items themselves, since their specs quote the placeholder syntax they're proposing to change.
  improvement: doc/tool-level — scan only the template's own placeholder positions (known at template-authoring time) rather than regex-scanning the final filled string; or exclude the `## The spec under review` / verbatim-spec block from the survivor scan. Low frequency (only affects items whose spec text itself contains `<UPPER_SNAKE>`-shaped substrings), so likely stays a doc note (mention in `help brief`) rather than a gate. Candidate for filing only if it recurs.
- goal: set up one fresh worktree per builder agent per orchestrate doctrine ("never nested inside another checkout").
  actually happened: for `RxN2_253n` I initially created the worktree with `git worktree add ... origin/main` like the other five items, before checking its `show` output said `base: board` — had to remove the worktree, delete the branch, re-fetch `origin/board`, and recreate it correctly off `origin/board`. Cost: one wasted worktree creation + a `git worktree remove --force` + `git branch -D`, ~1 minute.
  contributed: my own sequencing, not the tool: `gitboard brief builder ID`'s "Where to work" section already correctly read "branched off the latest `origin/board`" for this item (verified afterward) — the tool derives the base branch correctly. I built the worktree from a quick per-item skim of `show` output before generating any briefs, batched across six items, and missed the one whose base differed from the other five.
  improvement: process, not tool — generate each item's brief FIRST (it states the correct base inline), then create the worktree from the brief's own text, rather than pre-creating worktrees from a separate `show` skim. No countermeasure item filed; this one is on the orchestrator, not the board tooling.

## candidates
- orchestrator bare-session claim lock (doc fix to `help orchestrate`/`help take`) — filed as «31gDVoi5»
- spurious `<N>`/`<REVIEW_SESSION>` placeholder-survivor false positives when an item's own spec quotes `<UPPER_SNAKE>`-shaped text — stays here for triage: low frequency (only board-tooling items whose spec discusses placeholder syntax), noted but not filed
- pre-existing bootstrap snippet `git worktree add o/board board` fails on a session with no prior board worktree (needs `git fetch origin board` first) — stays here for triage: minor, one-line workaround, not yet filed as its own item

## build cOu8_PnMv (claude) — PR #1680, wall=210s, tool_calls=26
Transcript (`cosmic _tool/friction.tl`): events=113 tool_calls=26 wall=210s;
tokens in=44 out=162 cache_read=1370176 cache_create=78426; by tool:
Bash=19 Edit=2 Read=2 Skill=1 ToolSearch=1
mcp__github__create_pull_request=1; first edit: call 8; errors=0;
repeated commands: x4 read of `cosmic/check.tl`, x2 `git diff`.
Agent's own account: "None worth reporting. The spec's line number,
evidence quote, and suggested rewording all matched the current tree
exactly ... so this was a straightforward one-line edit with no
ambiguity to resolve." No friction — spec and tree matched exactly,
low tool-call count, single edit, clean PR.

## build xcBt_YwKh (claude) — PR #1681, wall=250s, tool_calls=28
Transcript: events=119 tool_calls=28 wall=250s; tokens in=50 out=155
cache_read=1946042 cache_create=73128; by tool: Bash=12 Edit=4 Grep=6
Read=4 ToolSearch=1 mcp__github__create_pull_request=1; first edit:
call 12; errors=0; repeated commands: x3 each on
`_make/resolution_test.tl` and `_make/runverb.tl`, x2 the narrowed
test run. Agent's own account: "None worth logging — the spec's line
numbers, wording, and evidence ... all matched the current tree
exactly, so the change and test were mechanical to produce and
verify." No friction — spec matched, mutation test completed as
instructed, clean PR.

## review cOu8_PnMv (claude) — no verdict (CI running), wall=26s, tool_calls=5
Transcript: events=27 tool_calls=5 wall=26s; tokens in=8 out=11
cache_read=173521 cache_create=31972; by tool: ToolSearch=1
mcp__github__pull_request_read=4; no edits (review-only); errors=0.
Agent's own account: PR's checks were all freshly queued/in_progress
(~2 minutes old) at review start; correctly stopped per protocol
without recording a verdict, rather than polling or waiting.
Not friction in the countermeasure sense — this is inherent to
reviewing a PR immediately after the orchestrator spawns a review for
a build that just landed inside the same pass; a future pass's normal
`next`/`take` cycle re-offers this review once CI settles. Cost was
minimal (5 tool calls, 26s).
