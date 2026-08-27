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
