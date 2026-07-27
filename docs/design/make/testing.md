# Tests

How a test runs, and what it can see. The [verbs](verbs.md) chapter
covers `test`'s command line; this is the model underneath it.

Same rule as generators: **inputs = grants = your staged subtree.**

- **writes:** `TEST_TMPDIR` only; anything else is a denial, on the
  author's machine, at the moment it happens.
- **reads:** the staged subtree rooted at the test's own directory, plus
  the staged module tree it imports. Other packages' sources, `$HOME`,
  and the live tree are denied.
- **one shared stage** per run, so reads are of an immutable snapshot —
  removing the read-a-file-another-test-is-writing class and costing one
  stage, not one per test. Immutability is enforced twice: Landlock
  restrictions are inherited across `exec`, so a test's children are
  fenced too; and the stage is chmodded read-only (`0444`/`0555`) so the
  guarantee survives on hosts without Landlock, where the in-process
  gate covers a test's own IO but **not** what it spawns.
- fixtures need no special grant — anything in the test's subtree is
  readable. `testdata/` exists solely to keep fixtures **out of the
  artifact**.
- ambient environment is redirected into the test's directory
  (`TMPDIR`, `HOME`, `XDG_*`, cwd), with `TEST_SRCDIR` pointing at the
  staged subtree.
- `testrun`'s `.got`/`.out`/`.err` contract and `status_of` (0 pass /
  2 skip / other fail) are unchanged.
- **selection is by path**, several accepted, globbed by the caller's
  shell (`cosmic --make test cosmic/sqlite/*_test.tl`). No filter flag —
  the shell already does that better. Selection changes which tests
  run, never what gets staged: a partial stage would resolve differently
  than a full one.

**Ports remain a known, documented gap** — fencing can't see them.

Consequence here: ratchet tests that read the live tree
(`makefile_ratchet_test.tl`, the cast and coverage ratchets) **move to
where their inputs are** — the project root, whose subtree is the whole
staged tree.
