---
name: ship
description: Take a change from implementation to a pull request in cosmic, following doc/contributing.md -- tested, adversarially reviewed by a separate agent, its TODOs listed -- and set to auto-merge unless told not to. Use when asked to implement and ship a change, or a list of changes as a sequence of PRs or, through subagents, in parallel.
argument-hint: "[no-automerge] <what to change>"
---

# Ship a change

Follow [`doc/contributing.md`] and [`AGENTS.md`] for everything below;
this file adds the order of work and the review prompt.

Auto-merge is the default. When the arguments start with `no-automerge`,
or the user asks in any words not to merge automatically, leave the PR
for a person once CI is green. A leading `automerge` asks for the
default and is dropped from what to change.

## Sequence

1. Split the work into standalone PRs and take them in order, one
   through merge before the next. With `no-automerge`, a next PR that
   does not depend on an open one starts from main now; when only
   dependent ones remain, stop and report which PRs remain and what each
   waits on.
2. Implement in a fresh worktree and branch, check, and commit, per the
   guide.
3. Start a separate read-only agent with a fresh context and the prompt
   below. Fix every BLOCKING finding and each cheap, plainly right nit;
   say in the PR description why any are left. Review again after a
   large fix.
4. Take the TODO list from `bin/cosmic todos` (again after merging a
   moved main), push, and open the PR.
5. Enable auto-merge. Watch both the branch's run and the merge queue's.
   On a failure, find the cause and fix it; never skip or disable a test
   to get green. A queue-only build failure in code the change did not
   touch: never queue the same head again; see [`doc/contributing.md`]
   ("merge").
   Once merged, clean up the worktree and branch.
6. When the change adds what a `TODO:` waiting on the pin needs, open
   the pin bump once the prerelease exists; otherwise say the pin was
   left alone.

Removing code can leave a marker stale (the `-- checked: ...` comment
that holds a finding of the checker on its line, see "ceilings only fall"
in [`doc/contributing.md`]); `bin/cosmic fix .` removes it, and the
whole-tree check refuses it until then; changing a harness
module bumps `epoch` or sets `acknowledged` in
[`build/harness_epoch.tl`], as [`doc/testing.md`] says. Both are found by
`bin/cosmic fix --check .` and the tests, run as step 2 and the guide's
"check before pushing" say.

## Several changes at once, through subagents

When the user asks for a batch of independent changes in parallel, this
section replaces step 1's order for the independent ones; a change that
depends on another, or shares a file with it, still waits for it. The
session that plans the batch coordinates, and each change gets an
implementing subagent of its own, in its own worktree and branch.

- A subagent cannot start another agent, so it cannot run step 3. Tell
  it to commit, run the checks and hand back "ready for review" without
  pushing. The coordinator starts the reviewer and sends the findings
  back; only then does the implementer push, open the PR and enable
  auto-merge. If a PR was pushed before its review, disable its
  auto-merge until the review is clean.
- The coordinator subscribes to each PR, alone, so its events reach one
  session: it fixes or relays CI failures and, once a PR merges, cleans
  up its worktree, branch and build directory.
- Before starting, list the files each change will touch. Changes that
  share one (a test helper, a signature many callers pass, the `epoch`
  line of
  [`build/harness_epoch.tl`]) go one after another: the later starts
  from main once the earlier merges, or merges `origin/main` as the
  guide says, since the merge queue drops a PR on any conflict and does
  not update it.
- Each implementer boots a tree and runs the whole suite, so run no more
  at once than `nproc` reports.
- Each finding an auditing agent reports is a claim to check against the
  code before acting on it. One that does not hold is skipped, and the
  PR says so.

## Reviewer prompt

Fill in the angle brackets. Give the reviewer the goal and the diff, not
your conclusions about whether it is right.

```text
You are reviewing a change to cosmic. Break it; do not praise it. Edit
nothing.

Goal: <what the change is meant to do, in the user's words>
Worktree: <absolute path>
Diff: run `git diff origin/main...HEAD` there.

Check, against the code rather than the diff's story:
- Revert the fix (keep the new test) and confirm the test fails. A test
  that passes without the fix is BLOCKING.
- Cases the change gets wrong: edge inputs, failure paths, other
  callers (`bin/cosmic uses <symbol>`).
- Rules in AGENTS.md, including doc/c.md's checklist when C changed, and
  TODO policy: a gap left with no `TODO:` naming what it waits on.
- Comments against doc/writing.md: correct, necessary, no narrative.
- A harness module changed without the epoch or acknowledged digests
  set as doc/testing.md says.
- A deleted test: name the test that still checks what it checked, or
  call the deletion BLOCKING. Where copies were replaced by a shared
  helper, diff each copy against it.
- Run `bin/cosmic fix --check .` and report its result.

Report one line per finding, most severe first:
BLOCKING|nit <file>:<line> <claim> -- <evidence: command run, output>
Before saying "no findings", list what you checked.
```

[`AGENTS.md`]: ../../../AGENTS.md
[`build/harness_epoch.tl`]: ../../../build/harness_epoch.tl
[`doc/contributing.md`]: ../../../doc/contributing.md
[`doc/testing.md`]: ../../../doc/testing.md
