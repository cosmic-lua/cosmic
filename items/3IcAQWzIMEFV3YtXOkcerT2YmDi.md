## Change

Evidence (2026-08-30): `skills/work/SKILL.md` documents the id forms
verbs accept (full KSUID, unambiguous prefix, tail-8 handle, lines
43-47) and separately says branches are "named for the id prefix"
(line 158) — but never states that these are two DIFFERENT 8-char
strings for one item: the branch name is the id's FIRST 8 characters
while the rendered handle is the LAST 8, so a session that copies a
rendered handle «d0x1_37YJ» and looks for a branch by that string
finds nothing. The change, prose only, one sentence in
`skills/work/SKILL.md` beside the existing handle paragraph (or the
branch-naming sentence — wherever it reads most naturally): the
branch for an item is named by the id's first-8 PREFIX, which is not
the rendered tail-8 handle — the two are different strings for the
same item, and verbs accept either. House voice, compact.

## Non-goals

No tool changes (verbs already accept all forms); no changes to
branch-naming conventions.
