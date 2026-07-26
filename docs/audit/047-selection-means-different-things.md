# 047 — selection narrows targets for `test`/`fmt`, but truncates the pipeline for `build`

severity: medium (surprising verb semantics; worth settling before users learn it)
type: design / feature
area: docs/design/make.md verbs; `_make/init.tl`

## observation

path selection means different things per verb:

- `test [paths]` / `fmt [paths]` / `check [paths]`: run the same verb
  over fewer targets. the design even states the invariant crisply for
  tests: "selection changes which tests run, never what gets staged."
- `build [paths]`: does something categorically different — it compiles
  the selected sources and **stops before any artifact**
  (`run_graph`: artifacts are built only when `#paths == 0`). the
  verdict reports a compile, not a build.

so `cosmic --make build cmd/foo` — whose natural reading is "build the
`foo` binary" — type-checks and compiles some files and produces no
`o/bin/foo`. the user asking for exactly one binary of a multi-binary
project (the `multi` fixture's whole scenario) has no spelling for it;
the user who typed it gets a success verdict for something they did
not ask for.

## proposal

one rule for every graph verb: **selection names targets of the verb's
own kind, and never changes what a target means.**

- `build cmd/foo` (or `build foo`) builds binary `foo` — full pipeline,
  same staging a full build gives it (mirroring the test invariant, so
  a selected build cannot resolve differently than a full one).
- `build pkg/db.tl` — a source path — can keep meaning "compile-check
  this", but then it is a different verb wearing build's name; `check`
  already means that. consider refusing source paths for `build` and
  pointing at `check`, which makes the verb's noun consistent: build
  takes binaries, test takes tests, fmt takes files.

this also future-proofs `run [path]` (planned), which will need
"path names a binary" semantics anyway — better that `build` and `run`
agree on what a path is before both exist.
