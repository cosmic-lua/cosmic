## Change

Measured 2026-08-30: the id forms are documented only in
`_work/gitboard.tl`'s module doc COMMENT (lines 13-15: KSUIDs, tail-8
handle, prefix) — the printed `gitboard help` output (built from the
verb table around line 92) says nothing about them, and nothing
anywhere states that an item's BRANCH is named by the id's first-8
prefix while renders show the tail-8 handle — two different 8-char
strings for one item, a live confusion for sessions copying a rendered
handle and hunting for a branch. The change, in `_work/gitboard.tl`
(and its help-rendering module if the text lives elsewhere — follow
`gitboard help`'s actual assembly): the top-level `gitboard help`
output gains a short ids paragraph (3-4 lines, after the command list
or with the summary) stating: ids are KSUIDs; the board renders each
item by its handle, the id's LAST 8 characters («d0x1_37YJ»), accepted
by every verb bare or wrapped, any divider, any case; an unambiguous
prefix or the full id also work everywhere; item BRANCHES are named by
the id's FIRST 8 characters — a different string from the handle. Pin
the new help text by substring in the existing help-output test seam
(find it: `grep -rn 'help' _work/gitboard_test.tl`); mutation-verify
the pin. Per-verb help is untouched.

## Non-goals

No SKILL.md changes (the skill defers verb docs to the tool). No
change to what forms verbs accept. No renaming of branches or handles.
