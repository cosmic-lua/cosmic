## Evidence

`_work/spec.tl`'s `section_of` (lines 88-113) ends a section at the
NEXT heading of ANY depth — `line:match("^#+%s+(.-)%s*$")` — so a
`###` sub-heading inside `## Result` truncates the section to whatever
precedes it. `move ID check --evidence` refuses a handover whose
`## Result` is empty (`_work/gitverbs.tl:137`), but a truncated
section is not empty, so the refusal never fires and the reviewer's
`--section result` read silently shows a fraction of the findings.

Observed on 3IU0GxoA: its first rework's Result was structured with
four `###` sub-headings (`### The durable record (review point 5)`,
etc.), so everything from the 40 per-run rows onward — including the
Conclusion — sat outside what `section_of("Result")` returns. The
handover was accepted and the item reached review anyway. 3ISWHyP7's
Result records the same trap as prose learned the hard way ("no `###`
sub-heading may appear inside it — `section_of` breaks at the NEXT
heading of any depth"), which is a workaround living in one item's
spec rather than a property the tool enforces or the writer is told
about.

Two candidate fixes, not chosen here: make the evidence handover
refuse (or warn on) a `## Result` followed by a deeper heading before
the next `##`, or make `section_of` treat a DEEPER heading as part of
the current section and break only at one of equal or shallower depth,
which is what a markdown reader would do. The second changes a shared
grammar (the ready bar reads the same function) and needs its own
look at `ready_gaps`.
