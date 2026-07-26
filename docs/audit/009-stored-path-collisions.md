# 009 — stored-path collisions in the artifact resolve nondeterministically

severity: medium
type: bug
area: `_make/artifact.tl`, `_make/validate.tl`

## issue

distinct kinds can map to the same *stored* path inside the artifact:

- payload `embed/pkg/db.lua` vs module `pkg/db.tl` — both store `pkg/db.lua`
- committed `embed/x` vs generated `o/<unit>/embed/x`
- payload `embed/main.lua` vs the entry's own `main.lua`

`plan()` sorts entries with `a.stored < b.stored`; for equal keys
`table.sort`'s order is unspecified, and `stage()` writes both — last one
wins. which bytes ship can vary between runs, silently. the validator checks
*import*-path duplicates but has no stored-path rule.

## where

- `_make/artifact.tl:262-290` — `plan` builds and sorts the entry list.
- `_make/artifact.tl:302-334` — `stage` writes every entry; collisions
  overwrite.
- the artifact.tl comment "nothing downstream can tell which was which"
  (about committed vs generated `embed/`) describes exactly the ambiguous
  case.

## failure scenario

a project vendors a compiled module as payload (`embed/pkg/db.lua`) while
also having source `pkg/db.tl`. some builds ship the vendored copy, others
the compiled one, depending on sort stability — a heisenbug at the artifact
level.

## suggested fix

detect stored-path collisions in `plan()` after assembling the entry list
(one linear scan over the sorted list) and refuse with both origins named:
`make: pkg/db.lua: staged by both embed/pkg/db.lua and pkg/db.tl`. if a
deliberate override order is ever wanted (e.g. generated beats committed),
make it explicit and documented rather than sort-order luck.

## test to add

an artifact test with a payload file colliding with a module's compiled
path, asserting a refusal naming both sources.
