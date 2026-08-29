`skills/work/review.md` on `main` tells a reviewer to read `verdict_head`
alone: "the item's `verdict_head` records which commit was judged, so a
reviewer can see at a glance whether anything new followed the verdict —
read it before re-reviewing, and treat an unmoved head as nothing to
judge" (`grep -n "unmoved head" skills/work/review.md` → line 128 of that
file at 28cfe511). That sentence is the human half of the same wrong
assumption the `verdict` guard makes: a rework that the bounce clause
itself invites — a bounce on the Evidence, answered by moving only the
spec sidecar and the PR body — leaves the head unmoved and is NOT
nothing to judge. Item 3IZtg3eG fixes the tool half on the `board`
branch and cannot reach `skills/**`, which lives on `main`. The sentence
needs re-writing to say that a reviewer reads BOTH the judged head and
whether the spec moved since, which `gitboard show` renders once
3IZtg3eG lands.
