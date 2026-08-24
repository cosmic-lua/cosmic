## Goal

G3 — the batteries are discoverable. A cosmic artifact is already a
queryable SQL database of itself, through the `zipfile` virtual table
that `cosmic.sqlite` reaches with no wrapper and no format change, and
nothing the binary ships says so. This slice makes the capability
reachable by someone who has only the binary: one guide
(`cosmic --docs guide.artifacts`) and one runnable example.

## Evidence

All measured 2026-08-24 against the pinned release the trust root
fetches — `bin/cosmic --version` prints `cosmic-lua unknown (cosmos
2026.08.14-c3201810e, Lua 5.4)`, the binary at `o/bootstrap/cosmic`
(10,952,199 bytes). Every query below was run through
`cosmic.sqlite`'s `db:query` against a `:memory:` database, the
artifact passed as a bound parameter.

**Nothing in the tree mentions it.** `grep -rn zipfile --include=*.tl
--include=*.md . | grep -v '^./o/'` returns nothing. `ls docs/guides/`
is 12 files — checking, docs, formatting, gotchas, index, lint, make,
modules, platforms, quickstart, recipes, testing — none about
artifacts or SQL. `grep -c artifacts docs/guides/index.md` is 0.

**Reading works.** `SELECT count(*) FROM zipfile(?)` over the binary
is **554** members. Grouped, which is the shape the guide leads with:

```
SELECT substr(name, 1, instr(name || '/', '/')) AS top,
       count(*) AS n, sum(sz) AS bytes
  FROM zipfile(?) GROUP BY top ORDER BY bytes DESC LIMIT 6

.tl/       n=203  bytes=1765985
.docs/     n=1    bytes=1667833
make       n=1    bytes=1587632
cosmic/    n=110  bytes=361467
tl.lua     n=1    bytes=338897
.types/    n=11   bytes=260114
```

**Extraction works, and the caveat is real.** `SELECT CAST(data AS
TEXT) FROM zipfile(?) WHERE name = 'cosmic.mk'` returns the 13,031
bytes of `embed/cosmic.mk`, beginning `# cosmic.mk — the rules for
`cosmic --make`.`; `sys/help.md` (4,073) comes out the same way. But
`cosmic/json.lua` is 1,799 bytes whose first four are `\27Lua` — the
embedded modules are precompiled bytecode, not source, so a reader who
expects to `SELECT` their way to Teal gets a chunk header. That is the
first honest caveat and it belongs in the guide, not in a footnote.

**Writing works.** On a COPY (`fs.copy` then `fs.set_mode`, under
`fs.temp_dir()`):

```
CREATE VIRTUAL TABLE z USING zipfile('<copy>');
INSERT INTO z(name, data) VALUES ('hello.txt', 'hi from sql');
```

then `<copy> -e "print((io.open('/zip/hello.txt')):read('a'))"` prints
`hi from sql`. The edited binary still runs.

**Deleting works, and costs.** `DELETE FROM z WHERE name LIKE
'.docs/%'` removed the one `.docs/` member (1,667,833 bytes) and the
file went **10,952,199 → 10,990,210**, i.e. it GREW 38,011 bytes:
`zipfile` appends a fresh central directory and reclaims nothing.
Afterwards `<copy> -e "print('still runs')"` exits 0, while `<copy>
--docs fs` exits 1 — the binary survives losing its doc index and the
feature that needed it does not. That pair is the second caveat, and
the guide states both halves.

**Where the example gets its artifact.** `proc.interpreter()` returns
the running cosmic binary (`/home/user/cosmic/o/bootstrap/cosmic` in
this session), which is what an example may query hermetically; `arg[0]`
is the script path and is not it (`cosmic --docs proc`, and
`cosmic/child/init.tl:195` says so).

**Headroom.** `wc -l cosmic/doc/guide_test.tl` is 143 (357 under the
500-line cap); `wc -l cosmic/sqlite/init_example.tl` is 137, and
`cosmic/fs/` already carries two example files (`init_example.tl`,
`walk_example.tl`), so a second one under `cosmic/sqlite/` is an
established shape rather than a new one.

**What gates a new guide.** `_build/snippets_test.tl` declares
`--- reads: docs` and holds every fence in the population to two
rules: a ```teal fence must be a formatter fixpoint AND compile at
full strictness, warnings included. There is no opt-out word — a
block that is not compilable Teal says so by being tagged ```text or
```sql, never ```teal. `_build/guides_test.tl` walks every
`docs/guides/*.md`, but its whole-directory assertions only constrain
markdown TABLE ROWS: a row may say "asset" only about pins, and a row
whose first cell is "everything else" must say "never embedded".

## Change

Three files touched, one of them new twice.

**1. `docs/guides/artifacts.md`** (new) — the guide
`cosmic --docs guide.artifacts` serves. `cmd/cosmic/embed_gen.tl:71`
embeds `docs/guides` as a directory, so dropping the file in is the
whole registration; there is no topic list to edit. Structure it as
the Evidence above reads, in this order:

- what a cosmic artifact is (an executable zip) and the one-line
  claim: `SELECT name, sz FROM zipfile(?)` over the binary's own path
  needs no extraction step and no temporary file;
- **inspect** — the grouped query above, with the 554/`.tl/`/`.docs/`
  numbers as the illustrated output;
- **extract** — `CAST(data AS TEXT)` for `cosmic.mk` and
  `sys/help.md`, immediately followed by the bytecode caveat: an
  embedded module is a `\27Lua` chunk, and `cosmic --docs <module>`
  is how you read a module, not SQL;
- **edit** — `CREATE VIRTUAL TABLE ... USING zipfile()` plus INSERT,
  on a COPY, with the "it still runs" check spelled out; then DELETE
  with both measured halves (the file grows 38,011 bytes and reclaims
  nothing; the binary survives but `--docs` stops working);
- a closing note that this is stock SQLite over a stock zip, so the
  same queries work on any zip file, not just a cosmic artifact.

Every SQL block is fenced ```sql and every shell block ```text; a
```teal fence must be code the formatter and checker accept, so
prefer showing the Teal through the example file below and keeping
the guide's fences SQL. Any markdown table in the file avoids a row
saying "asset" and avoids a first cell of "everything else"
(`_build/guides_test.tl` constrains both).

**2. `cosmic/sqlite/zipfile_example.tl`** (new) — `Example_*`
functions the example runner extracts, in the shape of
`cosmic/sqlite/init_example.tl` (137 lines). It obtains its artifact
from `proc.interpreter()`, copies it under `fs.temp_dir()` with
`fs.copy` + `fs.set_mode(…, tonumber("755", 8))` BEFORE any statement
that writes, and never writes to the interpreter itself. Cover, one
function each: the grouped inspect query; extracting `cosmic.mk` as
text; inserting a member on the copy and running the copy to read it
back through `/zip/`; deleting a member and asserting the file did not
shrink. Fallible calls use `check.must` per AGENTS.md.

**3. `cosmic/doc/guide_test.tl`** (+~12 lines) — one
`test_guide_artifacts` in the shape of `test_guide_platforms`
(`:99-113`): spawn `{cosmic, "--docs", "guide.artifacts"}` with
`clean_env()`, assert it succeeds and that the output carries the
guide's H1 text and the string `zipfile`. Called on the line after its
`end`, as every test in the file is.

**4. `docs/guides/index.md`** (+1 line) — one bullet in the
"Detailed Guides" list, in the established
`- [topic](topic.md) — one line` form.

## Non-goals

- **No new module and no wrapper.** `cosmic.sqlite` reaches `zipfile`
  as it stands; do not add `cosmic.artifact`, `cosmic.zip`, or a
  helper to `cosmic/sqlite/**`. No file under `cosmic/sqlite/` is
  edited — only the new example file is added beside them.
- **Do not write the test suite.** Freezing the zipfile contract with
  a `cosmic/sqlite/` test file is board item `3IMcreeF`, deliberately
  separate: this slice documents, that one gates. An example is not a
  substitute and this slice does not become one.
- **Do not touch whilp/cosmopolitan.** The registration is one line in
  the fork (`tool/net/lsqlite3.c` calling `sqlite3_zipfile_init`).
  Frozen C boundary; nothing here changes it.
- **Do not touch `sys/help.md`.** Its guide list is a curated five out
  of twelve, not an index; adding a sixth is a separate judgment.
- **Do not edit any existing guide** beyond the single index.md
  bullet.
- **Nothing writes into the committed tree.** Every mutating statement
  in the example and in the guide's prose operates on a copy under
  `fs.temp_dir()`. An example that edited `o/bin/cosmic` in place
  would corrupt the toolchain mid-gate.
- **Do not claim `zipfile` reclaims space or edits in place.** It
  appends; the measured DELETE grew the file. Say so.

## Acceptance

Every command runs verbatim from the repo root and writes no committed
file.

- `bin/cosmic --make ci` ends `ci: PASS`. This is the floor and it
  includes `_build/snippets_test.tl`, which is what holds the guide's
  fences to the formatter and the checker.
- `bin/cosmic --make example cosmic/sqlite/zipfile_example.tl` passes.
- `bin/cosmic --make test cosmic/doc/guide_test.tl` passes, including
  the new `test_guide_artifacts`.
- `o/bin/cosmic --docs guide.artifacts` exits 0 and its output
  contains `zipfile` (it exits 1 today — `--docs guide.nonexistent`
  is the same path, asserted at `cosmic/doc/guide_test.tl:137-143`).
- `bin/cosmic --make test _build/guides_test.tl` passes — the
  whole-directory ratchet now walks one more file.
- `wc -l cosmic/sqlite/zipfile_example.tl` is ≤ 200. (Its sibling
  `init_example.tl` is 137; the cap is 500 and this bound is the
  slice's own.)
- `wc -l cosmic/doc/guide_test.tl` is ≤ 200 (143 today).
- `grep -c artifacts docs/guides/index.md` is ≥ 1 (0 today).

## Enablement

none needed. The capability is in the pinned release and was exercised
end to end today (Evidence); `docs/guides/**` already ships through
`cmd/cosmic/embed_gen.tl:71` with no list to register a topic in; the
example and doc-test shapes both have a sibling to copy
(`cosmic/sqlite/init_example.tl`, `cosmic/doc/guide_test.tl`'s
`test_guide_platforms`). `blocked_by` is empty: `3IMcreeF` is a
sibling that gates the same capability, and neither ordering blocks
the other — the docs do not need the test to exist, and the test does
not need the guide.
