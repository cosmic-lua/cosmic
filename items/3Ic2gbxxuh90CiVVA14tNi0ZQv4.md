Evidence (2026-08-30, follow-up to item 3Ibq27iI / PR #1544): decode
now tolerates content-problem items and `store.flagged_summary(items)`
formats the "N unreadable/flagged: <id8> — <reason>" line, but nothing
calls it — a flagged item is read past silently, so the operator never
learns a stored record needs repair (`set --title` can fix it, but
only if someone notices). The change: wire `flagged_summary` into the
board renders — bare `show` (and `next` if its output has a natural
place) prints the one summary line when any listed item is flagged;
`show <id>` on a flagged item names its problems. Touches
`_work/gitshow.tl` / `_work/gitview.tl` (+ tests); the formatter and
tolerance are already merged and untouched.
