## Evidence

Found by reviewing 3IVDirCO (PR #1460). Its `## Acceptance` says

```
git diff origin/main --name-only   → exactly skills/optimize/measurement.md
git diff origin/main -- _perf      → empty
```

Both are the TWO-DOT form, which diffs the working tree against
`origin/main`'s TIP rather than against the branch's merge base. On a
checkout that is behind main it therefore prints main's own forward
progress, and the bullet cannot be satisfied no matter what the branch
did. Measured on this review's scratch worktree — the PR's one commit
cherry-picked onto `267c2a4d`, two commits behind `origin/main`
(`54aa87df`):

```
git diff origin/main --name-only        → 114 files
git diff origin/main...HEAD --name-only → skills/optimize/measurement.md
git diff origin/main -- _perf | wc -c   → 32740
git diff origin/main...HEAD -- _perf | wc -c → 0
```

The second pair is the damaging one: the bullet whose entire job is to
prove a `## Non-goals` wall held ("no threshold moved") reads 32 KB of
somebody else's landed test migration and looks like a violation.

**This is a recurrence, and at least the third appearance.**

- 3IOXhlWb's spec already wrote the rule out in full: "The three-dot
  form diffs against the merge base, so it says what THIS branch
  changed and stays correct however far `main` has moved ahead", with
  its own measurement (49 files named on a clean checkout).
- 3IU0GxoA's `## Review 3` recorded it as a ready-bar note for the
  next spec of this shape — "cannot be satisfied on a checkout that is
  behind main … here it printed nine files".
- 3IVDirCO, refined in the pass immediately after that review, carries
  it twice.

Prevalence over the board today:

```
grep -h -o 'git diff[^`]*' items/*.md | grep origin/main | grep -v '\.\.\.' | wc -l   → 75
grep -h -o 'git diff[^`]*' items/*.md | grep 'origin/main\.\.\.' | wc -l              → 23
```

75 two-dot invocations across 57 item specs against 23 correct
three-dot ones. Prose in a review has now failed to move that ratio
twice; `enable.md`'s ordering says the countermeasure is core.

## Direction

A pure check in `_work/spec.tl` beside `ready_gaps`, surfaced by
`gitboard check` and by the ready gate in `_work/gitgate.tl`: read the
`Acceptance` section with the existing `section_of`, and refuse a `git
diff` invocation that names `origin/main` (or a bare `main`) without
`...`. The fix it names is mechanical — insert `...HEAD` — so the
message can say exactly that.

Scope to the `Acceptance` section: `## Evidence` legitimately quotes
tip-relative diffs as measurements of the tree as it stands.

Not proposed: rewriting the 57 existing specs. Ended items are a
record; the check binds what is refined from here.
