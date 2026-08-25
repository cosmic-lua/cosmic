## Goal

G5 — adversarial verification. A cosmic artifact is queryable and
writable through SQL because one line in the fork registers sqlite's
`zipfile` virtual table on every opened database
(`whilp/cosmopolitan` `tool/net/lsqlite3.c:2413`, inside
`lsqlite_do_open`, calling `sqlite3_zipfile_init(db->db, 0, 0)`). The
capability is documented (`docs/guides/artifacts.md`) and demonstrated
(`cosmic/sqlite/zipfile_example.tl`), and neither pins the parts that
would break silently: whether the module is registered at all, what
the table's columns are, and what its three failure modes say. This
slice adds the test file that freezes them.

## Evidence

Measured 2026-08-25 against `whilp/cosmic` `a0c4ebd7`, built with
`bin/cosmic --make fetch && bin/cosmic --make build` (`build: PASS`),
and against `whilp/cosmopolitan` master.

**The registration is one line, and nothing in cosmic names it.**

```
$ grep -n 'sqlite3_zipfile_init' ../cosmopolitan/tool/net/lsqlite3.c
2413:        sqlite3_zipfile_init(db->db, 0, 0);
$ grep -rn 'pragma_module_list' --include=*.tl .
(no matches)
```

**`pragma_module_list` is the direct sentinel and it works today.**
Run under `o/bin/cosmic --make test` from a scratch test file:

```
SELECT name FROM pragma_module_list WHERE name = 'zipfile'   ->  zipfile
```

**The example gates read/insert/delete but asserts nothing else.**
`cosmic/sqlite/zipfile_example.tl` is 134 lines
(`wc -l < cosmic/sqlite/zipfile_example.tl`), runs in `--make ci`'s
`example` stage, and matches printed output. It never selects `mode`,
`mtime`, `rawdata` or `method`, and never exercises a failure path.

**All three failure modes return clean, deterministic strings.**
Measured from a scratch `cosmic/sqlite/*_test.tl` under
`o/bin/cosmic --make test` (the file was removed afterwards;
`git status --short` is empty):

```
duplicate INSERT of an existing name -> false, 'duplicate name: "probe.txt"'
zipfile() over a non-zip file        -> nil,   'cannot find end of central directory record'
zipfile() over a missing path        -> nil,   'cannot open file: <path>'
```

**The round trip runs inside the test harness.** The same scratch file
copied the interpreter into `TEST_TMPDIR`, inserted a member, ran the
copy, and deleted the member: `test: PASS (1 file)`, wall 30ms. Under
`--make test` the interpreter is a real artifact
(`o/.testrun/cosmic`, 10,380,538 bytes, 641 members) and
`TEST_TMPDIR` is per-test-file. **641 is this build's number, not a
contract** — assert `> 0` and named members, never a count.

**Neither committed floor moves.** Test files are not coverage rows
(`grep -c '_test.tl' .cosmic-coverage` is 0), so a new test file does
not drift the file set; it can only raise existing rows, which the
ratchet permits. And `grep -c 'cosmic/sqlite/zipfile' \
_build/casts_baseline.tl` is 0 — a file with zero `as` casts needs no
row, which is why `## Change` forbids casts outright.

## Change

Add one new file, `cosmic/sqlite/zipfile_test.tl` (absent today:
`ls cosmic/sqlite/zipfile_test.tl` reports No such file). Follow
`cosmic/sqlite/data_test.tl` for shape: module-level
`local TEST_TMPDIR = os.getenv("TEST_TMPDIR")`, `cosmic.*` requires
only, `check.must` for fallible returns, each `test_*` function called
on the line after its `end`.

Write exactly these five test functions, in this order:

1. `test_zipfile_module_is_registered` — open `:memory:`, then
   `query_one("SELECT name FROM pragma_module_list WHERE name = 'zipfile'")`
   and assert the row's `name` is `"zipfile"`, with a failure message
   naming `sqlite3_zipfile_init` in `tool/net/lsqlite3.c` as what to
   look at. This is the sentinel: it fails loudly and specifically if
   an upstream merge drops the registration.

2. `test_artifact_members_are_readable` — `proc.interpreter()` for the
   artifact path, then assert `count(*) FROM zipfile(?)` is greater
   than zero and that a `SELECT name` for `'cosmic/fs.lua'` returns
   that member. Do not assert any total.

3. `test_every_documented_column_is_selectable` — one
   `SELECT name, mode, mtime, sz, rawdata, data, method FROM zipfile(?)
   WHERE name = 'cosmic/fs.lua'`, asserting each of the seven columns
   is non-nil. These are the columns `docs/guides/artifacts.md:17-19`
   documents.

4. `test_insert_and_delete_round_trip` — `fs.copy` the interpreter to
   `fs.join(TEST_TMPDIR, "artifact")`; `CREATE VIRTUAL TABLE z USING
   zipfile('<copy>')`; `INSERT INTO z(name, data)` a member named
   `zipfile_test.txt` with a known body; close; `child.run` the copy
   with `-e` reading `/zip/zipfile_test.txt` and assert the body comes
   back; reopen, `DELETE FROM z WHERE name = 'zipfile_test.txt'`, and
   assert `count(*) FROM zipfile(?)` for that name is 0.

5. `test_failure_modes_report_their_cause` — three assertions on the
   error strings measured above: a second `INSERT` of an existing
   member name returns false with an error containing `duplicate name`;
   `zipfile()` over a file written with `fs.write(..., "not a zip")`
   fails with an error containing `end of central directory`; and
   `zipfile()` over a path under `TEST_TMPDIR` that was never created
   fails with an error containing `cannot open file`. Match with
   `s:find(needle, 1, true)` — a literal substring, never a pattern.

Write no `as` casts anywhere in the file: reach values through
`tostring`/`tonumber` instead, so `_build/casts_baseline.tl` needs no
row. Keep the file at or under 200 lines.

## Non-goals

- **Do not touch `cosmic/sqlite/zipfile_example.tl` or
  `docs/guides/artifacts.md`.** The example is the documentation and
  already gates read/insert/delete through `--make ci`'s `example`
  stage; this file pins what the example does not assert, and
  duplicating its output-matching assertions is the surplus a reviewer
  should cut.
- **Do not assert any member count, file size, or byte total.** They
  are properties of a particular build (641 members and 10,380,538
  bytes here), not of the contract.
- **Do not edit the artifact the test is running from.** Every write
  goes to an `fs.copy` under `TEST_TMPDIR`; a program that rewrites
  the zip it is executing from will fail.
- **Do not change anything in `whilp/cosmopolitan`.** This slice adds a
  test that observes the existing registration; it does not move it,
  rename it, or add a binding. The `cosmo.*` C boundary and
  `tool/net/definitions.lua` are frozen here.
- **Do not touch `cosmic/sqlite/*.tl` sources**, any other
  `cosmic/sqlite/*_test.tl`, `.cosmic-coverage`, or
  `_build/casts_baseline.tl`. `git diff --name-only main` must name
  exactly one file.
- **Do not add a `--docs` entry, a guide, or a new `cosmic.*` module.**
  No public surface moves, so `_build/public_surface_baseline.tl` stays
  as committed.
- **Do not use `cosmo.*` directly.** AGENTS.md restricts raw bindings to
  library internals; a test uses `cosmic.*`.

## Acceptance

All commands run verbatim from the `whilp/cosmic` repo root and write
only into `o/` and `TEST_TMPDIR`, neither of which is committed.

- `o/bin/cosmic --make test cosmic/sqlite/zipfile_test.tl` ends
  `test: PASS (1 file)` and reports 5 test functions.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `wc -l < cosmic/sqlite/zipfile_test.tl` is at most 200.
- `grep -c ' as ' cosmic/sqlite/zipfile_test.tl` is 0.
- `grep -c 'pragma_module_list' cosmic/sqlite/zipfile_test.tl` is 1
  (0 anywhere in the tree today:
  `grep -rn 'pragma_module_list' --include=*.tl .` has no matches).
- `grep -c '^local function test_' cosmic/sqlite/zipfile_test.tl` is 5.
- `git diff --name-only main` names exactly
  `cosmic/sqlite/zipfile_test.tl` and nothing else.
- **The sentinel discriminates.** Edit the test's
  `pragma_module_list` query in the working tree to look for a name
  that is not registered (`'zipfile_absent'`), re-run
  `o/bin/cosmic --make test cosmic/sqlite/zipfile_test.tl`, and confirm
  it ends `test: FAIL` naming
  `test_zipfile_module_is_registered`; then revert the edit and confirm
  `git diff --stat` is back to the one-file, no-op state. A negative
  assertion that cannot fail is worth nothing, so prove this one can.
  Quote both runs in the PR description.

If the coverage ratchet complains, run exactly the regen command its
failure message prints and commit the result — it is in scope. Do not
weaken the gate any other way. It is not expected to complain: test
files are not baseline rows.

## Enablement

none needed. Every fact above was measured in this tree during the
refinement pass that asserts it, including the five behaviours the new
tests will assert: a scratch `cosmic/sqlite/*_test.tl` ran the
registration query, the member reads, the copy-insert-run-delete round
trip and all three failure paths under `o/bin/cosmic --make test`
(`test: PASS`, 30ms), and was then removed, leaving the tree clean. The
claiming session is re-running measurements already taken, not
discovering the shape of the work. Conventions are AGENTS.md;
`cosmic/sqlite/data_test.tl` is the shape to copy.
