## Change

`skills/work/SKILL.md` (main repo) still describes ids by prefix alone — measured 2026-08-29, lines 43-44: "ids are KSUIDs; every verb accepts an unambiguous prefix." The board now renders every item by its handle — the id's last 8 characters, guillemet-wrapped and underscore-divided («d0x1_37YJ») — and every verb resolves that handle typed bare or wrapped, with either divider or none, case-tolerantly, alongside the full id and the head prefix. Extend that one sentence to say so, so a session reading the skill recognizes the handles the tool prints and knows it can type them back. One file, a few lines; no other SKILL.md content changes.

## Rework

The first review (head 980ee964) bounced this because the sentence
over-promised: secondary id slots (compare OTHER, attach PARENT, block
BLOCKER, new --parent) refused handles. The cure was in the tool, not
this diff: item 3IbN8f3E / PR #1520 (board squash bbbc9e53) routes all
secondary slots through the same resolve-with-tail-fallback as arg 1.
Re-measured 2026-08-29 at board HEAD carrying that merge: full id,
prefix, and the handle bare/wrapped, `_`/`-`/no divider, any case all
resolve in arg 1 and in every secondary slot; bogus and truncated
tails are refused. The diff is unchanged and now true as written.
