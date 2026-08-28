A verdict can record a `verdict_head` that is not the pull request head
it judged, and nothing refuses it. The value is then meaningless to
`land`, which is the one consumer that depends on it.

Observed 2026-08-27 on `3IVKVXoO`. A verdict recorded
`verdict_head 5b0d83a4`, which is a commit on the **board branch** — the
sibling item's own verdict commit — not a commit on the pull request it
judged. The PR head that review's own prose describes reading was
`4e7f7b17`.

## Why it matters

`land`'s contract is that a verdict judges ONE head: before a merge, the
PR's current head is compared against `verdict_head`, and a head that
moved since the accept means the diff needs a fresh review rather than a
merge. That check is the last gate before a squash-merge.

When `verdict_head` holds a sha from the wrong repository history, the
comparison cannot match the PR head, so the check either refuses a
legitimate land or — worse, depending on how a caller reads a mismatch —
gets waved through by a session that assumes the recorded value is
authoritative and the mismatch is noise. Either way the property the
field exists to guarantee is not guaranteed.

It is also silent. Nothing at verdict time asks whether the sha names a
commit reachable in the PR, and nothing at land time distinguishes "this
head moved" from "this value was never a PR head at all", so the defect
is invisible until someone reads the two shas side by side.

## Shape of a fix

At verdict time, when the item names a `pr`, resolve that PR's current
head and refuse a `--head` that does not match it — the same read `land`
already performs via `gh.pull`, so no new mechanism is needed. Deriving
the value instead of accepting it as a flag would close it outright: the
verb already knows the item and the item already carries the PR number,
so a caller-supplied head is an opportunity for error with no
corresponding benefit.

Worth checking during the fix whether other recorded verdicts carry the
same defect, since the value is written by hand today and this instance
was found by chance rather than by a check.

## The same field's other half, 2026-08-28: a stale verdict survives re-handover

A verdict is not cleared when an item returns to `check`, so an item can
carry a verdict whose head is not its PR's head — and, after a bounce to
a new PR, not even its PR.

Measured on the live board:

    3IVF3HbV   pr: #1480   verdict: reject (head 15cab039…)
    3IVHXoDw   pr: #1471   verdict: request changes (head 844da8a9…)

`15cab039` is the head of PR **#1463**, which was rejected and CLOSED;
`3IVF3HbV` was respecced and rebuilt as #1480, whose head is different.
`844da8a9` is `3IVHXoDw`'s pre-rework head; the rework pushed `e4579058`
plus a merge and handed the item back.

## Why it matters, stated precisely

It is not a soundness hole. `land` compares the PR's current head against
`verdict_head`, so a stale ACCEPT cannot land a reworked diff — the shas
differ and the verb refuses. The damage is to legibility, and it is real:
a reader sees `verdict: reject` beside `phase: check` and concludes the
current work was rejected.

That is not hypothetical. A session reading these two items reported them
as "verdicts sitting on work this session built — worth attention given
the reviewer-distance rule". Both verdicts were in fact recorded by OTHER
sessions against EARLIER heads. The stale field manufactured a
review-distance violation that did not exist, and a less careful reader
would have acted on it.

## Shape of a fix

The two halves belong together: this item already asks that `verdict`
refuse a `--head` that is not the PR's current head. The companion is
that a move INTO `check` clears any verdict whose head is not the head
being handed over — or, better, that `show` and `status` render a verdict
as stale when `verdict_head` does not match the PR's head, since that
needs no state change and cannot lose information.

Rendering is the safer half to build first: clearing risks discarding a
verdict someone still wants to read, while a `(stale)` marker costs
nothing and fixes the misreading directly.
