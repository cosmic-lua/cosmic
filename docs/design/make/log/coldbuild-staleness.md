# Cold-build ratchet: warm-tree field-widening reproduction

The reported one-run-late failure did **not** reproduce at
`840963d2a043d5c07d1eb48d0fad38b8d96a7b83`. The first full CI invocation
after the edit changed the cold-build ratchet's cached PASS to FAIL.
No invalidation change is justified by this experiment.

## Setup and exact edit

The host was macOS, using the unchanged bootstrap from
`bin/cosmic.pin`: release `2026-09-07-2b2002d`, SHA-256
`b4bb8bde84fc54c4298e4d63d949a1af071d2ff5a2e1ba095fa70d9e342ee434`.
Matching unpacked `o/3p` artifacts were copied from a local worktree
whose `3p` inputs were byte-identical. The bootstrap hash was verified
before running it. No bootstrap source or stamp was edited.

First build the unmodified tree and record a passing coverage result
for the actual test, not a substitute fixture:

```sh
sh o/bootstrap/cosmic --make build
bin/cosmic --make coverage _build/coldbuild_test.tl
```

The build passed and the selected coverage run reported
`coverage: PASS (1 file)`. Both test functions passed; the record
`o/.coverage/_build/coldbuild_test.tl.test.got` contained `0`, and its
`.in` content key existed. Preserve that warm `o/` unchanged.

Temporarily apply exactly this field-and-caller widening:

```diff
--- a/cosmic/doc/types.tl
+++ b/cosmic/doc/types.tl
@@
   record ModuleDoc
     file: string
     module_doc: string
+    parse_error: string | nil
--- a/_tool/doc/init.tl
+++ b/_tool/doc/init.tl
@@
-    (doc as {string: any})["parse_error"] = sigs_err -- cast: dynamic module boundary, avoids the cold-build snapshot mismatch a declared field would trip
+    doc.parse_error = sigs_err
```

Then run the full gate **once**, with no intervening build, selected
test, touch of the ratchet source, or removal of build outputs:

```sh
bin/cosmic --make ci --min 76 --min-file 0
```

This invocation ran outside the tool sandbox. The normal in-place
edit advanced both source mtimes beyond the cached `.got`; no source
mtime was artificially preserved or backdated.

## Observed first-run result

The log scheduled `record o/.coverage/_build/coldbuild_test.tl.test`.
Its `.got` became `1`, its old `.in` was removed, and its output named:

```text
_tool/doc/init.tl:177:9: error: invalid key 'parse_error' in record 'doc' of type ModuleDoc
```

The widened tree passed the format, type-check, example, and lint
stages. The ratchet nevertheless rejected it in that same invocation,
as intended. Its declared-tree listing stamp stayed byte-identical:
an in-place edit changed contents, not the set of filenames.

The whole gate was not green: unrelated host/runtime failures and
four stalled process/network/PTY test files also occurred. Those four
test children were terminated only after the ratchet's FAIL had been
recorded. Their termination did not produce the ratchet's diagnostic.
After capturing the result, both temporary source edits were restored.

## Why the first edit is visible

- `_make/imports.tl`'s `reads_of_file` expands each declared directory
  into individual sorted file paths, not a directory mtime. Both
  `cosmic/doc/types.tl` and `_tool/doc/init.tl` appeared in the generated
  `deps__build/coldbuild_test` variable before the edit.
- `_make/graph.tl` carries those paths into the test prerequisites and
  `--deps`; `embed/cosmic.mk` uses them for both plain and coverage
  records. A newer input schedules the recipe on this first run.
- `_cli/build/work.tl` hashes input names and bytes, and only reuses a
  recorded PASS with the same key. Changed source bytes cannot reuse
  that cached PASS once scheduled.
- `_make/readstamp.tl` separately hashes the sorted filename listing
  to schedule adds, deletes, and renames. It is not the content-change
  detector and correctly stayed unchanged in this experiment.

This establishes ordinary warm-tree edit timeliness at the named
base. It does not reconstruct the original session's partial build
state, intervening edits, or timestamp history. Those inputs would be
needed to re-specify a narrower missed-invalidation bug; the reported
one-run delay alone is not evidence for changing the cache now.

## Conservative guard versus real exposure

The sweep explicitly puts `/zip/.tl` before the tree for every file.
The real bootstrap-chain exposure (Path B) is narrower: the top-level
`--make` process can reach shipped modules via bare `require` before
compilation. Spawned generators get `--modules` through
`_make.closure` and `_make.generate`, so their built closure and
tree-first searcher precede the binary payload. The sweep deliberately
also checks modules reached only through that protected child path.

This experiment did not repeat a genuine empty-`o/` cold build and
does not claim to fix bootstrap-chain resolution. It confirms that
the conservative ratchet fires promptly for the ModuleDoc example;
its comments and diagnostic must not equate every such rejection
with a demonstrated real cold-build failure.
