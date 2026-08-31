## Change

Give templates a position-declared kind in the project model, so a `*.tmpl` in the
tree compiles to a module without the project writing a generator by hand.

The core item ships `cosmic.template.compile` as a library only, and build-time use
is an ordinary user `*_gen.tl` that reads a template and writes Teal. That was the
right first step — it needs nothing from `_make/` — but the generator is the same
five lines in every project, which is exactly the boilerplate the conventions exist
to delete. `*_test.tl` is a test, `*_example.tl` an example, `*_gen.tl` a
generator, `*_pin.tl` a pin: nothing lists these, position declares them.

Add `*.tmpl` to that vocabulary: a template at `x/y.tmpl` compiles to the module
`x.y` (or a spelling chosen during refinement — the collision with a sibling
`x/y.tl` has to be refused, not resolved silently).

### Where it lands

- `_make/project.tl` — the file kind and its import path.
- `_make/validate.tl` — refuse a `*.tmpl` colliding with a `*.tl` of the same
  import path; refuse a template whose `{{type … from …}}` names an import the
  project cannot resolve.
- `_make/generate.tl` — templates are generation units, so they run in the
  pre-graph pass with the other generators, against a strict-compiled closure.
- `_make/graph.tl`, `_make/deps.tl` — the generated module is a graph node, and the
  template plus the module its type directive names are its prerequisites, so
  editing either recompiles.
- `docs/design/make/model.md` — the kind, stated where the other kinds are.

### Prerequisite

Do not pull this before there are real templates. A convention is forever, and the
evidence that the hand-written generator is repetitive should come from projects
that wrote one — not from predicting they will.

## Non-goals

- No change to `cosmic.template`'s API. This item adds a caller, not a feature.
- No template discovery inside packages or archives.
