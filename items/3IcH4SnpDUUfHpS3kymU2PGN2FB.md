## Problem

Three `cosmic/*_test.tl` files end with a top-level `print` announcing
that their cases passed:

- `cosmic/fs/times_test.tl:161` — `print("all fs times tests passed")`
- `cosmic/format/types_test.tl:369`
- `cosmic/format/literal_format_test.tl:67`

Under legacy semantics the self-calls above them had already run, so
the line was true when it printed. Under runner mode (D29) the seam's
generated tail runs the cases AFTER the whole chunk, so the epilogue
fires at module load — before a single case has executed — and the
output asserts something not yet true. Nothing fails: the runner's own
summary is what actually reports, which is exactly why no gate catches
it.

Evidence: found while building batch 3/7 of the tree-migration
container (3IOCdooE) against origin/main 259400ce; the three lines were
left untouched because the batch specs' Non-goals forbid semantic
edits. The same shape may exist elsewhere in the tree — a sweep for a
top-level `print` in a `*_test.tl` is what sizes this.

The change is probably deletion (the runner's summary supersedes these
lines) rather than relocation, but the sweep has not been run and the
count is unmeasured, so this needs refinement to the spec bar before it
is pullable.
