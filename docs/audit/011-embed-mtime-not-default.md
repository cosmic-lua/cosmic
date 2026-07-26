# 011 — plain `cosmic --embed` output is not reproducible

severity: medium
type: bug (reproducibility)
area: `cosmic/embed/init.tl`, `_cli/main_handlers.tl`

## issue

the fixed-mtime plumbing exists and the `--make` path uses it:
`_make/artifact.tl:388` passes `mtime = embed.EPOCH`, and
`_make/artifact_test.tl:306` double-builds and compares sha256. but the
`--embed` CLI handler calls `embed.run(paths, output, exe)` with no options,
and `run()` does not default `opts.mtime`, so the zip binding falls back to
`time(NULL)` (cosmopolitan `tool/net/lzip.c:1113`). verified: two `--embed`
runs of the same inputs two seconds apart produce different sha256s.

## where

- `_cli/main_handlers.tl:264` — `embed.run(paths, output, exe)`; no opts.
- `cosmic/embed/init.tl:412` — mtime is forwarded when present; no default.
- `cosmic/embed/init.tl:448` — `EPOCH` is exported (DOS floor 315532800).

## failure scenario

any user building artifacts with `cosmic --embed` (rather than `--make`)
cannot get byte-identical rebuilds — breaking content-addressed caching,
signature workflows, and "same inputs, same binary" expectations the design
promises for `--make`-built artifacts.

## suggested fix

default `opts.mtime` inside `embed.run()` to the floor epoch (honoring
`SOURCE_DATE_EPOCH` if the design wants it here too, per make.md's
reproducibility section) so every caller gets reproducible output unless it
explicitly opts into live mtimes. one-line change plus a doc line.

## test to add

an embed test building the same input twice (with a filesystem mtime change
in between) and asserting identical sha256 — the `--embed`-path twin of
`_make/artifact_test.tl:306`.
