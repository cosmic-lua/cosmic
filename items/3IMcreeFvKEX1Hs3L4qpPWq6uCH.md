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

**What the example already gates is off the table, function by
function.** Reviewed against the file on `main`:

- `Example_inspect_members` asserts `count(*) > 0` over
  `zipfile(proc.interpreter())` and that `SELECT name` for
  `'cosmic/fs.lua'` returns that member.
- `Example_add_member` copies the interpreter, `CREATE VIRTUAL
  TABLE`, `INSERT`s a member, `child.run`s the copy and matches the
  member's body read back through `/zip`.
- `Example_remove_member` `DELETE`s members and asserts the reread
  count is 0.

So a member-read test and an insert/run/delete round-trip test would
restate three gated examples in a second gated file, for a second
10 MB artifact copy and a second child spawn on every `--make ci`.
Three properties are left uncovered, and they are the whole slice:
whether the module is registered, what the columns are, and what the
failure paths say.

**All three failure modes return clean, deterministic strings.**
Measured from a scratch `cosmic/sqlite/*_test.tl` under
`o/bin/cosmic --make test` (the file was removed afterwards;
`git status --short` is empty):

```
duplicate INSERT of an existing name -> false, 'duplicate name: "probe.txt"'
zipfile() over a non-zip file        -> nil,   'cannot find end of central directory record'
zipfile() over a missing path        -> nil,   'cannot open file: <path>'
```

**The artifact is real inside the test harness.** Under `--make test`
the interpreter is a real artifact (`o/.testrun/cosmic`, 10,380,538
bytes, 641 members) and `TEST_TMPDIR` is per-test-file, so a test can
copy it and reach a named member. **641 is this build's number, not a
contract** — select members by name, never by count.

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

Write exactly these three test functions, in this order — one per
property the example leaves uncovered, and nothing else:

1. `test_zipfile_module_is_registered` — open `:memory:`, then
   `query_one("SELECT name FROM pragma_module_list WHERE name = 'zipfile'")`
   and assert the row's `name` is `"zipfile"`, with a failure message
   naming `sqlite3_zipfile_init` in `tool/net/lsqlite3.c` as what to
   look at. This is the sentinel: it fails loudly and specifically if
   an upstream merge drops the registration.

2. `test_every_documented_column_is_selectable` — `proc.interpreter()`
   for the artifact path, then one
   `SELECT name, mode, mtime, sz, rawdata, data, method FROM zipfile(?)
   WHERE name = 'cosmic/fs.lua'`, asserting each of the seven columns
   is non-nil. These are the columns `docs/guides/artifacts.md:17-19`
   documents. Selecting the member by name is what proves it is
   readable; do not add a separate count-the-members test, and do not
   assert any total.

3. `test_failure_modes_report_their_cause` — three assertions on the
   error strings measured above: a second `INSERT` of an existing
   member name returns false with an error containing `duplicate name`;
   `zipfile()` over a file written with `fs.write(..., "not a zip")`
   fails with an error containing `end of central directory`; and
   `zipfile()` over a path under `TEST_TMPDIR` that was never created
   fails with an error containing `cannot open file`. Match with
   `s:find(needle, 1, true)` — a literal substring, never a pattern.
   The duplicate-name path needs a writable archive, so `fs.copy` the
   interpreter to `fs.join(TEST_TMPDIR, "artifact")` and
   `CREATE VIRTUAL TABLE z USING zipfile('<copy>')` over the copy —
   never over the artifact the test is running from. This is the only
   test that copies the artifact.

Write no `as` casts anywhere in the file: reach values through
`tostring`/`tonumber` instead, so `_build/casts_baseline.tl` needs no
row. Keep the file at or under 120 lines.

## Non-goals

- **Do not touch `cosmic/sqlite/zipfile_example.tl` or
  `docs/guides/artifacts.md`.** The example is the documentation and
  already gates read/insert/delete through `--make ci`'s `example`
  stage; this file pins what the example does not assert, and
  duplicating its output-matching assertions is the surplus a reviewer
  should cut.
- **Do not re-test what `## Evidence` lists the example as gating.**
  No member-count test, no insert/run/delete round trip: both are
  `Example_inspect_members`, `Example_add_member` and
  `Example_remove_member` restated in a second gated file. If the
  three functions in `## Change` feel thin, that is the slice being
  the least thing, not a gap.
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
  `test: PASS (1 file)`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `wc -l < cosmic/sqlite/zipfile_test.tl` is at most 120.
- `grep -c ' as ' cosmic/sqlite/zipfile_test.tl` is 0.
- `grep -c 'pragma_module_list' cosmic/sqlite/zipfile_test.tl` is 1
  (0 anywhere in the tree today:
  `grep -rn 'pragma_module_list' --include=*.tl .` has no matches).
- `grep -c '^local function test_' cosmic/sqlite/zipfile_test.tl` is 3.
- `grep -c 'child.run\|count(\*)' cosmic/sqlite/zipfile_test.tl` is 0 —
  the two shapes the example already gates are absent by construction.
- `grep -c 'fs.copy' cosmic/sqlite/zipfile_test.tl` is 1: exactly one
  test copies the artifact.
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
refinement pass that asserts it: a scratch `cosmic/sqlite/*_test.tl`
ran the registration query, the member and column reads and all three
failure paths under `o/bin/cosmic --make test` (`test: PASS`, 30ms),
and was then removed, leaving the tree clean. The claiming session is
re-running measurements already taken, not discovering the shape of
the work. Conventions are AGENTS.md; `cosmic/sqlite/data_test.tl` is
the shape to copy.

**The wrong turn this spec took, on its first pass through `check`:**
`## Non-goals` told the reviewer that restating the example's
output-matching assertions was "the surplus a reviewer should cut",
while `## Change` mandated exactly that surplus as two of its five
functions — a member-count read and an insert/run/delete round trip.
A spec cannot both forbid a thing and enumerate it; the builder
followed `## Change` (correctly — it is the scope), so PR #1365 landed
in review carrying 151 lines where ~90 were the slice. The
countermeasure is in this spec, not elsewhere: `## Evidence` now names
what the example gates function by function, `## Change` asks for the
three uncovered properties only, and `## Acceptance` has grep bounds
that fail if the cut surplus comes back. The general lesson, if this
recurs: a `## Non-goals` bullet addressed to the reviewer rather than
to the builder is a smell — the constraint belongs in `## Change`,
where the person writing the diff will read it.
