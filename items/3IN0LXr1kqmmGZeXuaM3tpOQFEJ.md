Found reviewing PR #1357 (item 3IMiflQz), which inserted an
unattended-session paragraph into `skills/work/decompose.md`. The
insertion severed a paragraph that was already there.

Before, one paragraph ran: "... order the queue by leverage: the pair
whose answer cascades furthest through transitivity and the hierarchy
goes first. transitivity closes the untested pairs for you (A > B and
B > C settles A vs C, with nobody asked), so a handful of questions
orders a half-dozen outcomes. give byes to outcomes that are nearly
holding (finish, don't debate) or dormant."

The new paragraph landed between "goes first." and "transitivity
closes the untested pairs for you", with a blank line before it and
none after — so the transitivity sentence now reads as the tail of the
unattended-session paragraph, whose subject is a session with nobody
to ask, rather than of the leverage-ordering paragraph it explains.

Reproduce on `main` at 489bba2f: `sed -n '63,76p'
skills/work/decompose.md` shows "... while a stalled loop costs the
whole session." immediately followed by "transitivity closes the
untested pairs for you", no blank line between.

Fix is one blank line, or moving the inserted paragraph to after the
"give byes" sentence so the original paragraph stays whole. Prose
only; no gate covers markdown paragraph structure, which is why the
PR's green CI did not see it.
