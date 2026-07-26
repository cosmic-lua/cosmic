# 045 — assets ship by default; every other kind is opt-in by marker

severity: medium (design coherence; item 9 and the `.cosmicignore` dilemma are its symptoms)
type: design / feature
area: docs/design/make.md project model; `_make/project.tl`, `_make/artifact.tl`

## observation

the model's philosophy is *intent is declared by position or marker*:
a package is `*.tl` in a directory, a test is `*_test.*`, a pin is
`*.pin.tl`, a generator is `*.gen.tl`, payload is `embed/**`, internal
is `_`, fixtures are `testdata/`. every kind is something you *did*.

one row breaks the pattern: "everything else | an asset, embedded at
its relative path" (make.md:111). shipping is the default, not a
declaration — and the design's open problems cluster exactly there:

- **item 9**: cosmic's own artifact ships `docs/`, `mk/`, `Makefile`,
  `_perf/`, both agent files — 10.2 MB vs the makefile build's 8.7 —
  because a repo is full of files that are *about* the project, not
  *of* the artifact.
- **the `.cosmicignore` dilemma** ("not shipped" vs "not seen" as one
  knob, explicitly undecided): the second knob is only needed because
  shipping is implicit. an opt-in model has nothing to un-ship.
- **`testdata/`'s "only job is staying out of artifacts"**: a special
  case existing solely to carve an exception out of the implicit
  default. same for `.d.tl` ("include path, never embedded").

## proposal

make shipping opt-in, using the concept the design already has: an
artifact carries **its modules plus `embed/**`** (committed and
generated), and nothing else. `embed/` is already defined as "where a
project puts a file the layout rule cannot place" — this promotes it to
*the* place a non-module file gets shipped from.

what dissolves: item 9 resolves structurally (nothing to ignore);
`.cosmicignore` returns to a purely model-scoped knob or deletes;
`testdata/`'s ship-exclusion and `.d.tl`'s never-embedded rules stop
being exceptions — nothing ships un-asked, so there is nothing to
except.

what it costs: the asset-at-relative-path convenience. the worked
example's `schema.sql` becomes `embed/schema.sql`; cosmic's own
`sys/help.md` becomes `embed/sys/help.md`. one `git mv` per asset, and
the artifact's contents become greppable from the tree (`ls embed/` +
the module set) — the same enumerable-surface property the design
already bought for network and exec.

## why now

the `assets/` fixture and the layout rule are young; downstream
projects have not accreted implicit assets yet. this gets harder every
release it waits, and it should be decided before item 9 is "fixed" by
adding the second knob instead.
