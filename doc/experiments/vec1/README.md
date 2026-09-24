# vec1 experiments

A record of what vector search in `cosmic.sqlite` (vec1, #2027) is good
for in this tree, without an embedding model. Not wired into anything.

Vectors here come from the hashing trick (`vec.tl`): a bag of features
(words and word pairs for text, `path:line` for coverage) folded into a
fixed number of float32s with a sign bit, L2-normalised, stored in a
`vec1` table with a flat cosine index.

Each script is its own tree, run from this directory against a booted
checkout (`o/build.db`, `o/cosmic.db` three levels up):

```sh
cd doc/experiments/vec1
../../../o/bin/cosmic todos.tl [question]
../../../o/bin/cosmic cover.tl [near <path> <from> <to>]
../../../o/bin/cosmic docs.tl [question]
```

## findings (2026-09-24, 986 tests, 32 TODOs, 1413 doc comments)

### coverage per test (`cover.tl`): the strongest

Each test is the lines it covered in the last full run, weighted by
`log(tests / tests covering the line)`, so the startup every test runs
counts for nothing. 1.76M rows, 30,113 distinct lines, 1024 dimensions.

- tests aimed at a region. Exact coverage says all 986 tests run
  `Fs.read` (`cosmic.fs` 29-60), which ranks nothing. Nearest to that
  region: `cosmic.fs_test test_read_takes_a_file_in_the_one_read_its_size_asks_for`
  at 0.645, the next at 0.797. For `core/sqlite.c` 1-400:
  `cosmic.hash_test test_sql_knows_the_same_digests` and the
  `core.sqlite_test` cases.
- redundancy. Three cross-module pairs lie under 0.10 cosine distance;
  the closest, `build.importer_test test_finds_a_real_top_level_require`
  and `test.visibility_test test_entry_reachable_from_outside_by_its_own_bare_name`,
  at 0.065. The suite has little of it.
- cost: 6-9 s to read the rows and hash them in Lua; 986 k-nearest
  queries in about 1 s.

### TODOs (`todos.tl`): duplicates and themes

- seven TODOs are one piece of work, "replace this sh/Python with a
  Teal script run by `cosmic --standalone`": `bin/verify-codesign`,
  `ci/run-local`, `ci/bootstrap-driver.sh`, `eval/arena`,
  `eval/check/evidence`, `eval/check/notes`, `eval/summarize`.
- `ci/cosmic_ci/process.tl:69` and `ci/fixtures/launcher_test.tl:155`
  are the same TODO, both waiting on a pin carrying patch/tl/24 and 25.
- `cosmic/shape.tl:85` and `:105` sit together (spec features).

At 32 TODOs a grep for "once" does most of this; the vector earns its
place as a "a similar TODO exists at ..." check when one is written.

### doc comments (`docs.tl`): not without a model

Hashed words find only shared words. "hash a file to verify a
download" misses `Http.download`'s `sha256`; FTS5, which `cosmic docs`
already has, does as well. No cross-module near-duplicates under 0.25.
Question-shaped search needs a real embedding model.

## where it could go

1. `cosmic test` runs the tests nearest the changed lines first, for an
   earlier failure; the same index answers `cosmic tests <file:line>`,
   beside `cosmic uses`. The vectors would be written into `build.db`
   when coverage is, not rebuilt in Lua per query.
2. `cosmic fix` notes a new `TODO:` that is near an existing one.
3. a redundancy line in the coverage report.

Not a fit: choosing an uncaught error's catalog guidance, which the
roadmap already settles as an exact match on a row's own text, and
question-shaped `cosmic docs` search until there is a model.
