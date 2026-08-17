# items/

The work board: one item per `<ksuid>.tl` (coordination state, read by
`cosmic.literal`) with its spec prose in the matching `<ksuid>.md`.
Operated by `_work/gitboard.tl`; the shape and rules are
`docs/design/work-state/README.md`. Excluded from the build model by
the root `.cosmicignore` — these files are data, not sources.

Imported from the `work:*` labeled GitHub issues on 2026-08-17; each
spec's first line names its source issue. Roles derive from the graph:
a ranked root is a goal, an unranked root is a finding, an item with
open children is a container, a parented leaf is workable.
