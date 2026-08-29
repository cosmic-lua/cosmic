Evidence (review flow of PR #1533, 2026-08-29): the already-judged
refusal in `_work/gitverdict.tl` now advises appending a Rework note via
`gitboard spec`, then recording the verdict against the new revision.
Followed by the SAME session, that advice trips two further refusals in
turn: `gitboard spec` refuses without `--base`, and the verdict then
trips the distance guard (the speccer is recorded on the item and may
not judge it). Each refusal chains correctly and the path stays walkable
for a fresh reviewer, but the same-session case dead-ends unless the
operator knows `--force --why` exists for repair. The change is message
text only: the already-judged refusal (or the guards it chains into)
names `--force --why` for the same-session repair case, pinned by a
substring assertion as the current text already is.
