# 008 — make-significant characters missing from the filename gate

severity: medium
type: bug
area: `_make/validate.tl`, `embed/cosmic.mk`

## issue

the validator refuses filenames containing shell metacharacters so that
"recipe splitting is total and quoting never exists" (make.md). but the
generated `o/project.mk` and the constant `embed/cosmic.mk` are **make**
input, and make's own significant characters are not in the gate: `%`, `:`,
`=` (and arguably `,` inside function calls). such names pass validation and
then land in variable values, target lines, and prerequisite lists.

## where

- `_make/validate.tl:55` — `METACHARACTERS` covers shell characters; `%`,
  `:`, `=` absent. (the `%s` whitespace check does cover tab/newline.)
- `embed/cosmic.mk:41-60` — pattern rules and `patsubst` machinery a literal
  `%` in a path breaks.

## failure scenarios

- `a=b.tl`: in a `foo := a=b.tl` assignment it survives, but anywhere it
  appears left of a rule colon it parses as a variable assignment (`=`
  before `:`), silently corrupting the graph.
- `a:b.tl`: splits a target/prerequisite list at the colon.
- `pct%file.tl`: a literal `%` in a prerequisite interacts with pattern-rule
  stem substitution, matching or expanding wrongly.

all are silent-misbuild shapes, not clean refusals — the opposite of the
design's "refused, by name" posture for spaces.

## suggested fix

add `%`, `:`, `=` (and `,`) to `METACHARACTERS`. the design already accepts
rejecting legitimate-but-hostile names ("a legitimate `my notes.tl` is
rejected, by name"); the same argument covers these.

## test to add

validator tests asserting each of `a=b.tl`, `a:b.tl`, `a%b.tl` is refused
with the filename-character message.
