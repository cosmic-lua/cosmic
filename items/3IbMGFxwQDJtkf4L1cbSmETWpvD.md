## Change

The machinery's id prose predates the tail handle. Measured 2026-08-29 (`grep -rn "unambiguous prefix" _work/*.tl README.md`): `_work/gitboard.tl:13` says "Ids are KSUIDs; every verb accepts an unambiguous prefix", `_work/store.tl:137` likens prefixes to git short hashes, and `README.md:12` describes items/ by ksuid alone — none mentions that renders lead with the handle («d0x1_37YJ», the id's last 8 chars) or that verbs resolve it (bare or wrapped, either divider, case-tolerant). Update those three prose sites to state the handle beside the prefix. Comment/doc lines only; no behavior, no tests beyond what fmt requires.

## Rework

Bounced 2026-08-29 (review-3IbMGFxw-1788029209): the new prose promised handle acceptance in every id slot while five secondary slots (compare OTHER, attach PARENT, new --parent, block/unblock BLOCKER) refused handles. The cure landed outside this PR as item 3IbN8f3E / PR #1520 (bbbc9e53 on board), routing all five secondary slots through the tail fallback; this PR's head 7c600b2f is unchanged by design. Re-review verifies the bounce probes resolve on current board HEAD.
