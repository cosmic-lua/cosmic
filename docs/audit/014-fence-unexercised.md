# 014 — derived fence is unexercised in production and its floor is incomplete

severity: medium (posture gap, matches design intent but worth stating plainly)
type: security / gap
area: `_cli/driver.tl`, `_cli/fence_test.tl`, cook.mk lanes

## issue

two related facts, both by design but easy to misread from the docs:

1. **nothing sets `COSMIC_FENCE=1` in any live lane.** the derived-grant
   fence is exercised only by `_cli/fence_test.tl` (A/B on one script, in
   the privileged `enforce` lane). every real recipe today is enforced by
   the old landlock-make `.PLEDGE`/`.UNVEIL` path in cook.mk — the derived
   model that make.md presents as the enforcement story enforces nothing in
   production yet.
2. **the fence floor is incomplete for real work.** when `COSMIC_FENCE=1`,
   `plan()` grants src, deps, `/dev`, `TMPDIR`, the APE loader, and
   `arg[-1]` — but not `tlconfig.lua` nor the `TL_PATH`/`_types` include
   dirs a `--compile-strict` reads. flipping the fence on for real recipes
   would deny those reads and break every compile.

## where

- `_cli/driver.tl:255-296,316-318` — `plan()` and the fence gate.
- `_cli/fence_test.tl` — the only exercise.
- `cook.mk:228` — comment noting the opt-in.
- make-plan.md:262-266 — "opt-in until the canary proves it on a Landlock
  host".

## why it matters

the gap between "documented enforcement model" and "actual enforcement
model" is the kind that outlives its authors. the fence cannot become the
default until its floor covers the compile inputs, and no issue or test
names that today — this file is the record.

## suggested fix

1. extend the fence floor: grant `tlconfig.lua` and the include dirs the
   compile verbs actually read (derive from the same place the compile step
   finds them, not a hand list).
2. add a CI lane on a Landlock host that runs one real compile under
   `COSMIC_FENCE=1` — the canary make-plan.md asks for.
3. only then schedule the default flip, as its own change.
