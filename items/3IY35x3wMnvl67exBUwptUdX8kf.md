## Evidence

Two sessions built `3IUBNQZZ` at once and opened two PRs for it — #1484
(`claude/3IUBNQZZ-cross-window-noise`, `7167dbe9`) and #1485
(`claude/3IUBNQZZ-compare-rows`, `37ea41cb`), both off `3ff022d3`, both four
files, both the same change. The board's claim did NOT fail to prevent this.
It held correctly, and was then overwritten by a direct file edit.

The item's whole history has exactly ONE claim and ONE handover:

```
$ git log --oneline -- items/3IUBNQZZ8UHrBZD8Tgb7BgEx2zD.tl
95858214 set 3IUBNQZZ in check
19240f1f move 3IUBNQZZ do -> check
0ae54065 move 3IUBNQZZ ready -> do
```

What each wrote:

```
$ git show 19240f1f -- items/     # 14:28:50
-  ["phase"] = "do",
+  ["phase"] = "check",
+  ["pr"] = 1484,

$ git show 95858214 -- items/     # 14:28:55, five seconds later
-  ["claim"] = "0b13d2b4-bb26-5bc1-8635-407acd85452c/3IUBNQZZ",
+  ["claim"] = "05f7c552-0c90-51cb-99b3-e018759c6ed5",
-  ["pr"] = 1484,
+  ["pr"] = 1485,
```

`19240f1f` is a `move`: the claiming session handed its work over through the
verb, and the verb enforced the claim (it first REFUSED an environment-derived
identity that did not match the minted claim, which is the check working).
`95858214` is not a verb at all —

```
$ ./o/bin/gitboard help | grep -c '  set '
0
```

— so it is the `SKILL.md` escape hatch ("when the tool LACKS a verb the
session needs, work around it ONCE by editing the item file and committing").
That path writes the file directly and therefore passes through none of the
gates a `move` applies. It silently replaced another session's live claim and
discarded the PR reference that claim had produced.

## Why this is the claim's whole value

A claim is described as a lock — "the move is the lock" — and the review
distance rests on it: `flow.built_by` reads `claim` and `builders` to decide
who may not judge an item. An edit path that rewrites `claim` with no check
means the lock is advisory against the one operation that can erase it, and
the durable `builders` record is the only thing that still remembers who
actually built #1484.

The cost here was one duplicated implementation (two agents, ~110k tokens,
two green CI runs) and an orphaned PR. The worse cost is latent: an item whose
`claim` has been rewritten can be routed for review to the session that built
it, because `built_by` no longer names them.

## Not asserted here

Whether the fix is to give the escape hatch a verb with the same gates, to
refuse an item-file commit that changes `claim` or `pr` while a live claim is
held by another session, to make the hatch append to `builders` rather than
replace `claim`, or to detect the duplicate at `move ... check` (a second PR
number arriving for an item already in `check` is the observable symptom).
The escape hatch is deliberate and load-bearing; narrowing it is a reviewed
change to the machinery, not a call this capture makes.
