# 003 — full `--make fmt` and selected `fmt` disagree on the file set

severity: high
type: bug
area: `_make/graph.tl`, `_make/init.tl`

## issue

the makefile facts writer adds **every** `.tl` path to `fmt_sources`
regardless of kind — including `testdata/` fixtures and `embed/**` payload.
the selection table for the `fmt` verb excludes both kinds. so
`cosmic --make fmt` (full, via the graph) and `cosmic --make fmt db`
(selected) format-gate different sets of files.

## where

- `_make/graph.tl:100-104` — `project_mk` appends any path matching `%.tl$`
  to `fmt_sources`, without consulting `f.kind`.
- `_make/init.tl:73-77` — `SELECTS.fmt` lists the kinds a selected fmt
  accepts; `testdata` and `payload` are not among them.

## failure scenarios

1. a project keeps a deliberately-broken fixture, e.g.
   `db/testdata/broken.tl` containing `"this is not teal at all ((` — the
   exact shape `_make/check_test.tl` itself uses. `--make check` passes
   (testdata is excluded from the model), but full `--make fmt` fails on the
   fixture.
2. a project vendors verbatim `.tl` sources as payload (the design blesses
   this — e.g. `embed/.tl/cosmic/fs.tl` is how cosmic ships its own sources).
   full `fmt` format-gates the vendored payload; selected `fmt` does not.

## why the existing test misses it

`_make/graph_test.tl:100` asserts "testdata must not reach the graph" using a
`.json` fixture — the `.tl`-suffix branch in `project_mk` is what leaks, and
a `.json` file never enters it.

## suggested fix

filter `fmt_sources` by kind in `project_mk`, using the same kind set as
`SELECTS.fmt`, so the two paths share one definition of "formattable".
extract the kind set to one place (e.g. a `FMT_KINDS` table both consult).

## test to add

a graph test with a `testdata/*.tl` fixture and an `embed/*.tl` payload file,
asserting neither appears in `fmt_sources` in the generated `o/project.mk`.
