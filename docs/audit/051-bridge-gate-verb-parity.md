# 051 — bridge removal: the ci gate has no `--make` equivalent yet

severity: blocker for 3i
type: gap (verb parity)
area: `_make/init.tl`, `embed/cosmic.mk`, Makefile `ci`

## what the bridge does today

`bin/make ci` is the repo's only gate: format + teal + model + test +
example + lint + coverage, parallel, with a `ci: PASS/FAIL` verdict
line. pr.yml runs nothing else.

## what `--make` has

`check`, `fmt`, `test` — three of the seven stages. missing:

- **`ci` itself** (planned): the fixed order with per-stage material
  gating, and the verdict-line contract CI parses.
- **`example`** and **`lint`**: in neither IMPLEMENTED nor PLANNED
  (audit 048); both are gate stages today (`mk/test.mk` example,
  `_build/lint.tl` lint — the 500-line cap and cast ratchet).
- **`coverage`** (planned) plus the `coverage-baseline` rewrite flow
  (`bin/make coverage-baseline` regenerates the committed floor —
  a verb option or a documented flag, but it needs a home).
- the **`model` stage dissolves** (running `--make check` from `--make
  ci` is just a stage), which is the one stage that gets simpler.

## also in the gate's orbit

- pr.yml's `enforce` lane (privileged, `COSMIC_ENFORCE=1`) and
  `reproducible` lane (`bin/make build` then `bin/make o=o2 build` —
  note the **alternate output directory**, a Makefile feature `--make`
  has no spelling for; the `reproducible` verb needs either an
  out-dir override or a different mechanism for building the same
  tree twice into comparable paths).
- `bin/make test only=sqlite` — the substring filter. `--make`'s
  path selection is the designed replacement and is strictly finer;
  no gap, but the skill docs and habits need the translation.

## exit criteria

`cosmic --make ci` runs all seven stages' worth of checking on this
repo, gated by material, ending in the same machine-readable verdict —
and a pr.yml lane runs it (see 056 for the dual-gate transition).
