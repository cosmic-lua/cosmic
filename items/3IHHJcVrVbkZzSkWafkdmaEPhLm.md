## Goal

G6 — no silent bugs in the C loop's own tooling. Every incremental build in
whilp/cosmopolitan ignores header edits, so any measurement or test run after
touching a header may be reading stale objects. That quietly undermines the
`optimize` skill's C-layer chapter (local A/Bs on a locally built lua) and every
edit-rebuild-re-run loop in that repo.

## Evidence

Measured 2026-08-23 against `whilp/cosmopolitan` at `bf92718a` (current
`master`), on a cold tree with no `o/` present.

**The bug, and its one-command root cause.**

```
$ make o//depend
… build/bootstrap/mkdeps -o o//depend … @o//srcs.txt @o//hdrs.txt @o//incs.txt
tclsqlite.h: path not specified by HDRS/SRCS/INCS make variables (it was included by third_party/sqlite3/sqlite3.c)
`make MODE= -j4 o//depend` exited with 1
make: *** No rule to make target 'o//depend'.  Stop.
```

`mkdeps` exits 1, so `o//depend` is never written; `-include o/$(MODE)/depend`
(`Makefile:670`) then includes nothing, so no object carries header
prerequisites, so editing a header rebuilds nothing.

**The user-visible consequence, measured today:**

```
$ make -j$(nproc) o//tool/lua/lua          # builds to completion
$ touch third_party/lua/luaconf.h
$ make -j$(nproc) o//tool/lua/lua
make: 'o//tool/lua/lua' is up to date.     # <- the bug
```

**`mkdeps` is a textual scanner.** It does not evaluate the preprocessor, so an
include sitting in a branch no compiler ever takes still has to resolve against
HDRS/SRCS/INCS, and one that cannot resolve hard-fails the entire dependency
graph. Exactly two includes in this tree are in that state, and both name
headers that do not exist anywhere in it — casualties of the fork's slimming.

1. **`tclsqlite.h`** — `third_party/sqlite3/sqlite3.c:203324`, inside
   `#ifdef SQLITE_TEST` opened at `:203322`. `SQLITE_TEST` is never defined for
   this build.

   ```
   203322  #ifdef SQLITE_TEST
   203323
   203324  #include "tclsqlite.h"
   ```

2. **`qrf.h`** — `third_party/sqlite3/shell.c:898`. `shell.c` is an amalgamation
   that INLINES `ext/qrf/qrf.h` at `:678-881`, and that inlined copy ends on
   `#endif /* !defined(SQLITE_QRF_H) */`, defining the guard. The include below
   it is a fallback that can never fire:

   ```
   897  #ifndef SQLITE_QRF_H
   898  #include "qrf.h"
   899  #endif
   ```

   `find . \( -name 'tclsqlite*' -o -name 'qrf*' \) -not -path './.cosmocc/*'`
   prints nothing: neither header exists.

**Exactly two — measured, not assumed.** `mkdeps` reports one missing header per
run and stops, so a bare run cannot say how many there are. The count was
established by stubbing the name it printed, re-running, and repeating until it
fell silent — then reverting every probe artifact. Starting from the
`tclsqlite.h` stub already in place, one more round settled it:

```
PROBE 1: missing qrf.h (from third_party/sqlite3/shell.c)
PROBE: mkdeps clean after 1 extra stubs
```

So: `tclsqlite.h`, then `qrf.h`, then clean — two headers total. Stubbing only
`tclsqlite.h` leaves `make o//depend` still failing, on `qrf.h`, so a one-header
fix delivers nothing observable: the depend graph is generated or it is not.

**The header list to edit** is `third_party/sqlite3/BUILD.mk:29-32`
(`wc -l` prints 201):

```
THIRD_PARTY_SQLITE3_A_HDRS =					\
	third_party/sqlite3/extensions.h			\
	third_party/sqlite3/sqlite3.h				\
	third_party/sqlite3/sqlite3ext.h
```

**Suspects cleared.** The `.DEFAULT` deletion at `Makefile:666`, the depend rule
at `:433` and the `-include` at `:670` are all correct — they were the original
report's suspects, and the evidence above clears them: if `o//depend` is
produced, they work. The two contradictory answers the original report gave are
also explained:

```
$ make depend
make: *** No rule to make target 'o//depend', needed by 'depend'.  Stop.
$ make -n o//depend
… build/bootstrap/mkdeps -o o//depend …
make: 'o//depend' is up to date.
```

`-n` prints the recipe without running it, so the failure never happens and make
reports the (absent) target current.

**Upstream is diagnosis, not a gate.** Upstream jart/cosmopolitan ships the Tcl
harness and the qrf extension sources, so both headers resolve there and `mkdeps`
succeeds — this is a fork-slimming artifact by construction. The local clone
cannot check it (`git log --oneline -- Makefile` shows 1 commit; the history is
squashed) and jart/cosmopolitan is outside this work's repository scope. Do not
gate on it.

## Change

Three files in **whilp/cosmopolitan**, on the designated branch. Nothing else
moves.

**1. `third_party/sqlite3/tclsqlite.h` — new file, a stub.** Header guard
`COSMOPOLITAN_THIRD_PARTY_SQLITE3_TCLSQLITE_H_` (the guard spelling
`third_party/sqlite3/extensions.h:1` uses, path-derived) plus a comment saying
what the file is for: the include in `sqlite3.c` sits under `#ifdef
SQLITE_TEST`, which is never defined here, so nothing compiles its contents, but
`mkdeps` scans textually and the path must resolve for the dependency graph to
build. No declarations, no vendored Tcl header. Use verbatim:

```c
#ifndef COSMOPOLITAN_THIRD_PARTY_SQLITE3_TCLSQLITE_H_
#define COSMOPOLITAN_THIRD_PARTY_SQLITE3_TCLSQLITE_H_
/* Placeholder for the Tcl test harness header, which this tree does not
   carry. third_party/sqlite3/sqlite3.c includes it under #ifdef
   SQLITE_TEST, which is never defined here, so no compiler ever reads it.
   build/bootstrap/mkdeps scans includes textually and does not evaluate
   #ifdef, so the path must still resolve against HDRS/SRCS/INCS or the
   whole o/$(MODE)/depend graph fails to build and every object loses its
   header prerequisites. Contents are deliberately empty. */
#endif /* COSMOPOLITAN_THIRD_PARTY_SQLITE3_TCLSQLITE_H_ */
```

**2. `third_party/sqlite3/qrf.h` — new file, a stub.** Same shape, guard
`COSMOPOLITAN_THIRD_PARTY_SQLITE3_QRF_H_`, comment naming its own reason: the
qrf sources are already inlined into `shell.c`, so the `#ifndef SQLITE_QRF_H`
fallback include below them can never fire, and only `mkdeps` ever reads the
path. Keep it under 15 lines and add no declarations — declaring anything risks
colliding with the inlined copy.

**3. `third_party/sqlite3/BUILD.mk:29-32` — list both.** Add
`third_party/sqlite3/qrf.h` and `third_party/sqlite3/tclsqlite.h` to
`THIRD_PARTY_SQLITE3_A_HDRS`, preserving the block's tab-and-backslash
continuation style with the backslashes aligned at column 64 as they are today,
and keeping the list alphabetical — which puts `qrf.h` first, before
`extensions.h`, and `tclsqlite.h` last, after `sqlite3ext.h`.
`THIRD_PARTY_SQLITE3_HDRS` at `:191` derives from the artifact lists by
`foreach` and needs no edit.

Note the `.ok` consequence at `BUILD.mk:53`
(`$(THIRD_PARTY_SQLITE3_A_HDRS:%=o/$(MODE)/%.ok)`): every listed header gets a
standalone compile check, so each stub must compile on its own. A guard-only
file does.

## Non-goals

- **Do not edit `third_party/sqlite3/sqlite3.c` or `third_party/sqlite3/shell.c`.**
  Both are vendored SQLite amalgamations. Deleting the dead includes would work,
  and would also put hand edits inside 200k+ vendored lines that every future
  re-vendor must re-apply. AGENTS.md: keep the fork mergeable with upstream —
  surgical diffs, no drive-by restructuring.
- **Do not modify `build/bootstrap/mkdeps` or its source.** Teaching the scanner
  to evaluate the preprocessor is a different, much larger change with its own
  correctness risk; the textual scan is deliberate.
- **Do not touch `Makefile`.** `:433`, `:666` and `:670` are cleared above.
- **Do not vendor the Tcl test harness or the qrf extension**, and do not define
  `SQLITE_TEST` or `SQLITE_QRF_H` anywhere.
- **No cosmic-side change.** No cosmos pin bump, no edit in whilp/cosmic. This
  slice lands in whilp/cosmopolitan only; consuming it is a later pin bump with
  its own item.
- **Do not widen this to a THIRD unresolved include.** The probe above says
  there is none. If `mkdeps` nonetheless names one after both stubs land, that
  is a finding for the board — file it with the failing output and stop, rather
  than absorbing it here.

## Acceptance

Run from the `whilp/cosmopolitan` checkout root. `make o//depend` is the whole
point; the `touch` pair is the reported bug turned into a pass condition.

```
make o//depend && ls -l o//depend
make -j$(nproc) o//tool/lua/lua
touch third_party/lua/luaconf.h && make -j$(nproc) o//tool/lua/lua
make -j$(nproc) o//tool/lua/test
grep -c 'third_party/sqlite3/' third_party/sqlite3/BUILD.mk
git diff --stat -- third_party/sqlite3/sqlite3.c third_party/sqlite3/shell.c build/bootstrap Makefile
git status --short
```

- `make o//depend` exits 0 and `ls -l o//depend` shows a non-empty file. It
  prints no `path not specified by HDRS/SRCS/INCS` line and no
  `NOTE: deleting o//depend` line. (Measured today: it exits 1 on `tclsqlite.h`,
  and `o//depend` does not exist.)
- the first `make -j$(nproc) o//tool/lua/lua` builds to completion.
- **the regression check**: after `touch third_party/lua/luaconf.h`, the second
  `make -j$(nproc) o//tool/lua/lua` RECOMPILES — its output names at least one
  `.o` being rebuilt and it does not answer `up to date`. (Measured today: it
  answers `make: 'o//tool/lua/lua' is up to date.`)
- `make -j$(nproc) o//tool/lua/test` passes, including the binding tests and the
  annotation-coverage ratchet (AGENTS.md names this the correctness gate before
  any PR here).
- `grep -c 'third_party/sqlite3/' third_party/sqlite3/BUILD.mk` prints a number
  25. It prints 23 today, so the two added header lines are the only new
  `third_party/sqlite3/` paths in the file.
- `git diff --stat` over the four walled paths prints nothing.
- `git status --short` lists exactly three paths: modified
  `third_party/sqlite3/BUILD.mk`, and `third_party/sqlite3/qrf.h` and
  `third_party/sqlite3/tclsqlite.h` added. No `o/` entries (it is gitignored).

## Enablement

none needed. Both failing commands and their exact errors are quoted above, each
dead include is cited by `file:line` with the preprocessor construct that makes
it dead, the header list to edit is quoted verbatim with its line range, the
`.ok`-per-header rule that constrains the stubs is named with the line that
imposes it (`BUILD.mk:53`), and the complete stub text for one of the two is
given to copy. The count of missing headers is measured rather than assumed, so
the implementer is not discovering scope at build time.

Wrong turns walled, in order of how tempting they are:

- editing a vendored amalgamation to delete a dead include — it works, and
  `Non-goals` bullet 1 explains the re-vendor cost that makes it the wrong fix.
- treating this as a `Makefile` bug, which is what the original report believed —
  `## Evidence` refutes it with the two contradictory `make` invocations and
  their explanation, and `Non-goals` bullet 3 walls the three suspect lines by
  number.
- fixing `tclsqlite.h` alone and stopping at the first green-looking step —
  `## Evidence` measures the second header and says a one-header fix leaves
  `make o//depend` still failing, so it delivers nothing.
- chasing an upstream diff first — answered from the mechanism and explicitly
  demoted from prerequisite to diagnosis, which matters because
  jart/cosmopolitan is outside this work's repository scope and the local clone's
  history is squashed.

The wrong turn this spec previously invited, in one line: it specified the
`tclsqlite.h` half, then walled the possibility of a second missing header
instead of measuring it, so its own `Acceptance` was unreachable by its own
`Non-goals`. The countermeasure is this spec, not a separate item — the gap was
one item's unmeasured consequence, not a systemic one, and the probe that closes
it costs a minute and is now written down.
