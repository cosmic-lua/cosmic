# 002 — a root `embed.gen.tl` never runs for `cmd/` binaries

severity: high (latent in this repo; real for user projects)
type: bug
area: `_make/artifact.tl`, `_make/init.tl`

## issue

`plan()` stages the root payload directory `o/embed/**` into **every** binary
— the code's own comment says "the root's belongs to every binary". but
`generate_payload()` only executes the generator at
`fs.join(binary.dir, "embed.gen.tl")` — the binary's *own* generator. a root
`embed.gen.tl` is compiled (it is in `compiled_kinds`) but is executed only
when the *root binary* is being built.

## where

- `_make/artifact.tl:232-256` — `generate_payload` runs only the binary's own
  `embed.gen.tl`.
- `_make/artifact.tl:262-274` — `plan` stages `generated_payload(proj.root,
  "", out)` (root `o/embed/**`) into every binary.
- `_make/init.tl:201-216` — `run_graph` iterates `proj.binaries` sorted by
  *name*, so even when a root binary exists, a `cmd/` binary that sorts
  before `basename(root)` stages root `o/embed/**` from the *previous* run.

## failure scenarios

1. a project with only `cmd/` binaries plus a root `embed.gen.tl`: the root
   generator never executes; every binary stages missing or stale root
   payload. first build fails confusingly (missing files) or silently ships
   nothing where payload was expected.
2. a project with a root binary named `zapp` and a cmd binary `alpha`:
   `alpha` is built first and stages root `o/embed/**` as left by the *last*
   build — freshness depends on the project's directory name.

this repo only uses `cmd/cosmic/embed.gen.tl`, so nothing here trips it; the
first downstream project with a root generator will.

## suggested fix

run the root generator once, before any binary's stage — either as an
explicit pre-pass in `run_graph`, or by making `generate_payload` also run
the root `embed.gen.tl` (deduplicated so it runs once per build, not once
per binary).

## test to add

`_make/generate_test.tl` covers only the per-cmd generator. add a fixture
with a root `embed.gen.tl` plus a `cmd/` binary and assert the cmd binary's
artifact carries the root generator's fresh output.
