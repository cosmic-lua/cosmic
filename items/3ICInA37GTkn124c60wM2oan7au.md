A negative assertion — `assert(not has(lines, pattern))` — passes for two
different reasons, and the test cannot tell them apart: the regression is
absent, or the pattern is dead. Nothing in the tree catches the second, and
it has now cost two review rounds on the same PR.

## Evidence

Both instances are on PR #1286 (board item `3I3z2gOF`), the same class in
two rounds:

1. 2026-08-19 review: `_work/gitverbs_test.tl:315` asserted the STORED field
   under the message "show renders the field" — a message claiming coverage
   the assertion did not provide.
2. 2026-08-20 review (the rework that closed #1 ): `_work/gitview_test.tl`'s
   new `test_repo_is_rendered_in_show_status_and_tree` guards the ` [repo]`
   mark from leaking onto same-repo lines with

   ```
   assert(not has(status_lines, "^pr: #42.*%["),
     "the same-repo LEAF is unmarked (regression guard)")
   ```

   `^pr: #42` is `show_report`'s grammar (`pr: #42` on its own line), not
   `status_report`'s: a status line is `("  %s %s%s")` over id, title and
   marks, where a PR renders as ` pr:42`. The pattern therefore matches no
   status line at all. Measured at `9f139552` against the PR's own fixture:
   the guard's pattern matches nothing, and it still matches nothing after
   deliberately setting `repo = "whilp/cosmopolitan"` on the same-repo LEAF —
   the exact regression it claims to catch:

   ```
   LINE: [  2YBXZfDO a leaf @session-a pr:42 [whilp/cosmopolitan]]
   pattern '^pr: #42.*%[' matches any line: false
   ```

## Why it recurs

The two report families use different grammars for the same fact (`show`
prints `pr: #42`, `status` prints `pr:42`), so a pattern copied from one
silently dies against the other, and a dead pattern in a NEGATIVE assertion
is indistinguishable from a passing guard. Coverage does not catch it: the
line runs.

## Direction (for refinement, not settled)

Core is available here and should be tried before docs: a `lacks(lines,
pattern)` helper that takes the control it needs — the pattern must match at
least one line of a sample where the guarded thing IS present, and match none
of `lines` — so a dead pattern fails loudly instead of passing. That turns
"this pattern is alive" from a reviewer's manual re-derivation into a
mechanical fact. Whether it belongs only in the board branch's test helpers
or generally (a `cosmic.check` idiom, a lint over `not ... :match` in
`*_test.tl`) is the refinement question.
