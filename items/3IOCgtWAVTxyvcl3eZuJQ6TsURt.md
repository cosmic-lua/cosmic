## Goal

G5 — adversarial verification. Once the salvage lands, `test/tool/net/**`
is 40 checks that run nowhere and assert contracts this fork replaced.
Deleting it makes `o//tool/lua/test` the whole correctness gate in the
tree, which is what AGENTS.md already says it is.

## Evidence

Measured 2026-08-25 against whilp/cosmopolitan `3c36bc35`. The parent
(`3INxo51I`) carries the full reasoning; the facts this slice acts on:

**Two references to the lane exist outside itself (corrected
2026-09-01 — the original evidence's grep pattern undercounted by
one; see below).**

```
$ grep -rn 'test/tool/net' --include=*.mk --include=*.yml --include=*.md . \
    | grep -v '^./test/tool/net'
./test/tool/BUILD.mk:9:		o/$(MODE)/test/tool/net		\
```

This was the original evidence's only hit, but `--include=*.mk` does
not match a file named plainly `Makefile` (no `.mk` extension), so it
silently excluded the repo root build file. A broader search without
that filter, re-run 2026-09-01 against `cosmic-lua/cosmopolitan`
master `d7f21d50` (confirmed also present at `origin/master` via
`git show origin/master:Makefile | grep -n test/tool/net`, so this is
not drift since the original pass — it was always there and the
original grep's glob simply missed it):

```
$ grep -rn 'test/tool/net' --exclude-dir=.git --exclude-dir=o .
./Makefile:399:include test/tool/net/BUILD.mk
./test/tool/BUILD.mk:9:		o/$(MODE)/test/tool/net		\
```

Root `Makefile:399` unconditionally `include`s `test/tool/net/BUILD.mk`.
GNU `make` errors on an `include` of a nonexistent file with no rule to
remake it, so deleting `test/tool/net/` without also removing this
line breaks `make` outright for every target in the tree — not just
the retired lane. This second reference is now folded into `##
Change` and `## Acceptance` below; the rest of the original evidence
(no workflow reference, the 12 failures being redbean's own contracts)
is unaffected and unchanged.

**It is in no workflow.** `grep -rn 'test/tool/net|tool/lua/test'
.github/workflows/` names only `o/x86_64/tool/lua/test`
(`pr.yml:26`, `release.yml:38`).

**The 12 failures are redbean's contracts, not drift.** Four
`:errno()` calls across `futex`/`mapshared`/`spinlock`/`sysconf`
against a fork that returns `nil, err:string, errno:integer` — as
`tool/lua/test_unix_errno.lua:20` states in a comment and asserts on
the next line. Two `module 'cosmo' not found` against a binary that
does not link `tool/lua/lcosmo.c`. `UnescapeParam` and argon2
`variants` are the same divergence from the binding side. Two more
(`lfetch`, `lfetchstream`) need a real network and were unmeasurable
in the sandbox that found this.

Re-verify both greps above at pull: if a new reference to the lane
appeared since, that is value drift — bounce rather than delete.

## Change

In cosmic-lua/cosmopolitan:

1. Delete the directory `test/tool/net/` entirely — all 40 test files,
   `redbean_test.c`, `sqlite_test.c`, and its `BUILD.mk`.
2. Delete line 9 of `test/tool/BUILD.mk`, the
   `o/$(MODE)/test/tool/net` entry in the `o/$(MODE)/test/tool`
   prerequisite list. Leave the other four entries (`args`, `build`,
   `plinko`, `viz`) and the trailing-backslash continuation of the
   line above it correct — the list is tab-indented and
   backslash-continued, so removing the last-but-one entry means
   fixing the continuation on whichever line becomes last.
3. Delete line 399 of the root `Makefile`, `include
   test/tool/net/BUILD.mk` — otherwise `make` errors on every target
   once the included file no longer exists.

Nothing else. This is a deletion, not a refactor.

## Non-goals

- **Do not start before the salvage child has landed.** It is a
  `blocked_by` edge, not a suggestion: deleting first loses the JSON
  conformance corpus, which `tool/lua/` does not otherwise have.
- **Do not touch `tool/lua/**`.** Porting is the other child's diff.
  If this slice finds something worth keeping that the salvage missed,
  that is a bounce (the inventory was wrong), not a widened diff.
- **Do not touch `.github/workflows/**`.** Neither workflow names the
  lane, so nothing there changes; if one does at pull time, bounce.
- **Do not touch the other four `test/tool/*` lanes** (`args`,
  `build`, `plinko`, `viz`) or any other `test/**` directory.
- **Do not change any binding.** The `cosmo.*` C boundary and
  `tool/net/definitions.lua` are frozen.
- **Do not touch anything in cosmic-lua/cosmic.**
- No other edit to the root `Makefile` beyond deleting line 399 — no
  reformatting, no reordering of neighboring `include` lines.

## Acceptance

Run from the cosmic-lua/cosmopolitan repo root.

- `ls test/tool/net` reports no such file or directory.
- `grep -rn 'test/tool/net' --exclude-dir=.git --exclude-dir=o .` has
  no matches.
- `make -j$(nproc) o//tool/lua/test` passes — the gate is unaffected.
- `make -j$(nproc) o//test/tool` passes, exercising the four remaining
  lanes through the edited prerequisite list. This is the check that
  proves the `BUILD.mk` continuation was not broken by the deletion;
  run it, do not eyeball the file.
- `git diff --stat master -- tool/ .github` is empty.
- `git diff --name-only master` names only `Makefile`,
  `test/tool/BUILD.mk`, and deletions under `test/tool/net/`.

## Enablement

blocked by the salvage child (mirrored in `blocked_by`). Nothing else:
the parent holds the decision and its evidence, and the change is a
directory deletion plus two lines. Conventions are
cosmic-lua/cosmopolitan's AGENTS.md — surgical diffs, keep the fork
mergeable with upstream.
