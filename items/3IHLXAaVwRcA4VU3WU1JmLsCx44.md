`gitboard show ID` prints fields, role, spec and git history as one
block, and has no option to narrow it (`gitboard help show` lists only
`--dir`). Reading a spec is therefore all-or-nothing.

The specs this board carries are not small. Measured 2026-08-22:

    338 items/3ICDHHW7UiksaaojXJyS6lMKdgp.md    (the spec sidecar)
     12 items/3ICDHHW7UiksaaojXJyS6lMKdgp.tl    (the item record)

A ready-bar spec is long BY DESIGN — it has to be implementable from
its own text — so this is not a spec to shorten. It is a read to
narrow.

Cost, from the 2026-08-22 scheduled session: pulling `3ICDHHW7` took
three separate `show` invocations piped through `head` and `sed` line
ranges to page the spec, plus a fourth for the history at the end.
Every one re-printed the fields header. Paging by line number also
means a session must guess where a section starts, and re-guess when
the spec grows.

What a session actually wants, in the order it wants it:

- **The spec alone**, when it has just claimed an item and is about to
  implement it. This is the common case and it is exactly the sidecar
  file, verbatim.
- **One section**, when it is re-checking a wall mid-implementation
  (`## Non-goals`) or quoting verdict lines at the end
  (`## Acceptance`). The section grammar is already known to the tool —
  `_work/spec.tl` enforces it for the ready bar — so a section
  selector needs no new parsing.
- **The fields without the spec**, when it is checking phase, claim,
  `pr`, `verdict_head` or blockers before deciding whether to read
  anything at all.

The workaround available today is reading `items/<ksuid>.md` directly
from the worktree, which is one read and gets the spec exactly. That
works, and it is what a session should do until this exists — but it
bypasses the tool, and the skill's rule is that board state reads and
moves go through `gitboard`. A read path that is worse than going
around it is the thing to fix.

Sketch, not a decision: `show --spec` for the sidecar alone, `show
--section Acceptance` for one section, `show --fields` for the record
without prose. Whether history stays in the default output, or moves
behind its own flag, is part of the same question — it is the part a
session almost never needs and it prints last, after the longest thing.
