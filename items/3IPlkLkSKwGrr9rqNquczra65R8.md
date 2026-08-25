`gitboard` has no verb that changes an item's title, so a title that
stops matching its own spec can only be fixed by hand-editing
`items/<ksuid>.tl` and committing — which bypasses the compare-and-swap
and the WIP re-check every other mutation goes through.

Refinement moves numbers. `3IOeg86u` is titled "close the 23
decoded-data shaping sites in non-test code with the validating decode"
and its refined spec closes 21: the two `_tool/coverage/report.tl`
sites turned out to need a `cosmic.shape` combinator that does not
exist, so they were excluded and captured separately. The title is what
`next`, `tree` and `status` print, so it is what a reviewer and every
future session reads first, and it now says a number the spec
contradicts. `spec` already replaces the sidecar wholesale; there is no
matching verb for the one line that lives on the item record.

Wanted: `gitboard title ID "new title"`, one commit, publishing like
every other mutation. Its acceptance is that the ordinary flow can fix
a stale title without a hand-written commit on `board`.
