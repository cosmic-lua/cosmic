An item cannot state which branch its PR targets, so work aimed at
anything but the default branch lives only in spec prose, invisible to
every verb. Verified 2026-08-26 on the board machinery: the item model
carries `repo` (`gitboard new --repo OWNER/NAME`) but no branch/base
field; the handover gate (`_work/gitgate.tl`, `handover_refusal`)
checks that the PR is open, not a draft, joined by its `Board:` line,
and not failing CI — never that its base matches what the spec
intends; and `land` (`_work/gitland.tl`) verifies only that the PR is
merged, into whatever base it declares. Meanwhile the workflow's
conventions hard-code main: the slice loop cuts branches off "the
latest origin/main" (skills/work/SKILL.md step 3, parallel.md), and
the ready-bar habit writes diff acceptance as
`git diff --name-only origin/main`. Today a non-main target works only
if the spec redefines the branch-cutting step and the diff base in
prose, and nothing catches a PR opened against the wrong base — the
same gap shape 3ID0uFdf records for the `repo` field (which no verb
can set after open). The fix wants a `base`/`branch` field on items,
settable at `new` (and repairable, unlike repo today), rendered by
`show`, with the check gate refusing a handover whose PR base
disagrees with it; the skill's branch-cutting and acceptance prose
then reads the field instead of assuming main.
