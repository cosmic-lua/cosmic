# 048 — `ci`'s documented pipeline contains stages no verb covers

severity: low (design completeness; blocks phase 4 as specified)
type: design / feature
area: docs/design/make.md verbs; `_make/init.tl:33-43`

## observation

make.md specifies `ci` as "format → check → test → **example** →
**lint** → coverage". cross-checked against the verb lists in
`_make/init.tl`: `example` and `lint` appear in neither `IMPLEMENTED`
nor `PLANNED`. the other stages all map (fmt, check, test, coverage).

`example` is especially incongruous: it is a first-class *kind* in the
model (`*_example.*` classifies, with the same scope semantics as a
test), the repo runs examples as a gate today (`bin/make example`), and
the public-module ratchet requires examples — but the verb set gives
them no runner. `lint` is the other half of today's gate
(500-line cap, cast justifications, `_build/lint.tl`) with no `--make`
home named anywhere.

phase 4 cannot deliver `ci` as specified while two of its six stages
have no verb to invoke.

## proposal

- add `example` to the planned verb set, specified as `test`'s sibling:
  same staging, same fence, `Example_*` runner instead of the test
  contract. the model already treats the two kinds symmetrically
  everywhere else; the verb set is the one place the symmetry breaks.
- decide where `lint` lives: either a planned `lint` verb (the style
  checks are already public in `cosmic.style`), or fold it into `check`
  and say so in the design — either answer works, but `ci`'s spec
  currently names a stage that resolves to nothing.
- naming both in `PLANNED` costs one line each, which is exactly what
  that list is for ("turns a typo-shaped failure into a schedule
  answer").
