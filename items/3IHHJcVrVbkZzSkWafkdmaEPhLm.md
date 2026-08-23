## Goal

No silent bugs, in the C loop's own tooling. Every incremental build in
whilp/cosmopolitan ignores header edits, so any measurement or test run after
touching a header may be reading stale objects. That quietly undermines the
`optimize` skill's C-layer chapter (local A/Bs on a locally built lua) and every
edit-rebuild-re-run loop in that repo.

## Evidence

**Root-caused 2026-08-23** against `whilp/cosmopolitan` at `07fc94a1` (the
commit the current cosmos pin `2026.08.21-07fc94a1c` was cut from), on a cold
tree with no `o/` present. The issue's diagnosis — a `.DEFAULT`-rule interaction
with the `-include` remake pass — is **not** the cause. One command names the
real one:

```
$ make o//depend
… -AMKDEPS -L320 build/bootstrap/mkdeps -o o//depend … @o//srcs.txt @o//hdrs.txt @o//incs.txt
tclsqlite.h: path not specified by HDRS/SRCS/INCS make variables (it was included by third_party/sqlite3/sqlite3.c)
`make MODE= -j4 o//depend` exited with 1
make: *** No rule to make target 'o//depend'.  Stop.
```

`mkdeps` exits 1, so `o//depend` is never written; `-include o/$(MODE)/depend`
(`Makefile:670`) then includes nothing, so no object carries header
prerequisites, so editing a header rebuilds nothing. The `.DEFAULT` deletion at
`Makefile:666` is downstream noise, not the trigger.

The two contradictory answers the issue reported are both explained by this:

```
$ make depend
make: *** No rule to make target 'o//depend', needed by 'depend'.  Stop.
$ make -n o//depend
… build/bootstrap/mkdeps -o o//depend …
make: 'o//depend' is up to date.
```

`-n` prints the recipe without running it, so the failure never happens and make
reports the (absent) target current.

**Why `tclsqlite.h` is unfindable.** It does not exist anywhere in the tree
(`find . -name 'tclsqlite*' -not -path './.cosmocc/*'` prints nothing) — the
fork's slimming dropped the Tcl test harness. The one reference is
`third_party/sqlite3/sqlite3.c:203324`, and it sits inside a dead preprocessor
branch:

```
203322  #ifdef SQLITE_TEST
203323
203324  #include "tclsqlite.h"
```

`SQLITE_TEST` is never defined for this build, so no compiler ever reads that
line. `mkdeps` is a TEXTUAL scanner — it does not evaluate `#ifdef` — so it sees
the include, cannot resolve it against HDRS/SRCS/INCS, and hard-fails the whole
dependency graph for one header that is never compiled.

The package's header list is `third_party/sqlite3/BUILD.mk:29-32`
(`wc -l` prints 201):

```
THIRD_PARTY_SQLITE3_A_HDRS =					\
	third_party/sqlite3/extensions.h			\
	third_party/sqlite3/sqlite3.h				\
	third_party/sqlite3/sqlite3ext.h
```

**Upstream comparison, and why it is not a prerequisite.** The issue's Direction
opened with "first establish whether upstream jart/cosmopolitan shows the same
behavior". That is now answerable from the mechanism instead of from a
checkout: upstream ships the Tcl harness, so `tclsqlite.h` resolves there and
`mkdeps` succeeds — this is a fork-slimming casualty by construction. The local
clone cannot check it anyway (`git log --oneline -- Makefile` shows 1 commit;
the history is squashed at `81ce7622`), and jart/cosmopolitan is outside this
work's repository scope. Treat it as diagnosis, not as a gate.

## Change

Two files in **whilp/cosmopolitan**, on the designated branch. Nothing else
moves.

**1. `third_party/sqlite3/tclsqlite.h` — new file, a stub.** Create it carrying
only a header guard and a comment saying what it is for: `mkdeps` scans includes
textually and cannot see that `sqlite3.c`'s reference is inside
`#ifdef SQLITE_TEST`, so the path must resolve for the dependency graph to build,
while the file's contents are never compiled. Do not add declarations; do not
vendor the real Tcl header. Keep it under 15 lines.

**2. `third_party/sqlite3/BUILD.mk:29-32` — list it.** Add
`third_party/sqlite3/tclsqlite.h` to `THIRD_PARTY_SQLITE3_A_HDRS`, preserving
the file's existing tab-and-backslash continuation style and alphabetical order
(it sorts before `sqlite3.h`, after `extensions.h`). `THIRD_PARTY_SQLITE3_HDRS`
at `:191` derives from the artifact lists by `foreach` and needs no edit.

Note the `.ok` consequence at `BUILD.mk:53`
(`$(THIRD_PARTY_SQLITE3_A_HDRS:%=o/$(MODE)/%.ok)`): every listed header gets a
compile check, so the stub must be self-contained and compile standalone. A
guard-only file does.

## Non-goals

- **Do not edit `third_party/sqlite3/sqlite3.c`.** It is a vendored SQLite
  amalgamation; deleting the `#ifdef SQLITE_TEST` block or its include would
  work, and would also put a hand edit inside 200k+ vendored lines that every
  future re-vendor must re-apply. AGENTS.md: keep the fork mergeable with
  upstream — surgical diffs, no drive-by restructuring.
- **Do not modify `build/bootstrap/mkdeps` or its source.** Teaching the
  scanner to evaluate `#ifdef` is a different, much larger change with its own
  correctness risk, and the textual scan is deliberate.
- **Do not touch `Makefile`.** `:433`'s depend rule, `:666`'s `.DEFAULT`
  deletion and `:670`'s `-include` are all correct; they were the issue's
  suspects and the evidence above clears them. If `o//depend` is produced, they
  work.
- **Do not vendor the Tcl test harness** or define `SQLITE_TEST` anywhere.
- **No cosmic-side change.** No cosmos pin bump, no edit in whilp/cosmic. This
  slice lands in whilp/cosmopolitan only; consuming it is a later pin bump with
  its own item.
- **Do not widen this to other unresolved includes.** If `mkdeps` names a
  SECOND missing header after this fix, that is a finding for the board, not
  scope to absorb here — record it and stop.

## Acceptance

Run from the `whilp/cosmopolitan` checkout root. `make depend` is the whole
point; the last two prove the fix is what the issue actually asked for.

```
make o//depend && ls -l o//depend
make -j$(nproc) o//tool/lua/lua
touch third_party/lua/luaconf.h && make -j$(nproc) o//tool/lua/lua
make -j$(nproc) o//tool/lua/test
git diff --stat -- third_party/sqlite3/sqlite3.c build/bootstrap Makefile
git status --short
```

- `make o//depend` exits 0 and `ls -l o//depend` shows a non-empty file. It
  prints no `path not specified by HDRS/SRCS/INCS` line and no
  `NOTE: deleting o//depend` line. (Today it exits 1 on `tclsqlite.h`, and
  `o//depend` does not exist.)
- the first `make o//tool/lua/lua` builds to completion.
- **the regression check**: after `touch third_party/lua/luaconf.h`, the second
  `make o//tool/lua/lua` RECOMPILES — its output names at least one `.o` being
  rebuilt and it does not answer `up to date`. This is the issue's own repro,
  inverted into a pass condition; today it answers up-to-date.
- `make -j$(nproc) o//tool/lua/test` passes, including the binding tests and the
  annotation-coverage ratchet (AGENTS.md names this the correctness gate before
  any PR here).
- `git diff --stat` over the three walled paths prints nothing.
- `git status --short` lists exactly two paths: modified
  `third_party/sqlite3/BUILD.mk` and untracked-then-added
  `third_party/sqlite3/tclsqlite.h`. No `o/` entries (it is gitignored).

## Enablement

none needed. The failing command and its exact error are quoted above, the
offending include is cited by `file:line` with the `#ifdef` that makes it dead,
the header list to edit is quoted verbatim with its line range, and the
`.ok`-per-header consequence that constrains the stub's contents is named with
the line that imposes it (`BUILD.mk:53`). The fix is two files and the
acceptance turns the issue's own repro into a pass condition, so "did it work"
is a command rather than a judgment.

Wrong turns walled, in order of how tempting they are:

- editing the vendored amalgamation to delete the dead include — it works, and
  `Non-goals` bullet 1 explains the re-vendor cost that makes it the wrong fix.
- treating this as a `Makefile` bug, which is what the item was imported
  believing — `## Evidence` refutes it with the two contradictory `make`
  invocations and their explanation, and `Non-goals` bullet 3 walls the three
  suspect lines by number.
- chasing an upstream diff first — answered from the mechanism in `## Evidence`
  and explicitly demoted from prerequisite to diagnosis, which matters because
  jart/cosmopolitan is outside this work's repository scope and the local clone's
  history is squashed.
