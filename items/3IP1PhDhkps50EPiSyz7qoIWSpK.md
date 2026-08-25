Refining item 3IOK4iuU on 2026-08-25 re-measured its class and changed what
the slice scopes: the title said "annotate the cosmo bindings that return any,
closing 13 from-any sites from definitions.lua", while the re-measured spec
scopes five sites, none of them in definitions.lua and none of them needing a
cosmopolitan change at all.

`gitboard help` lists no verb that changes a title — `spec` replaces the
sidecar only. The session worked around it under the "when the tool LACKS a
verb" rule: edited `items/3IOK4iuURwhfq3LSZ5sDHvmrt9z.tl` by hand and committed
(board commit `5246a920`), which bypasses the compare-and-swap the verbs go
through.

A title is what `next`, `status` and `tree` render, so an item whose title
contradicts its spec misleads every read of the board until someone opens the
sidecar. Refinement routinely changes what an item is; that this needs a hand
edit and a raw push makes it either rare-by-friction or done unsafely.

Evidence for a `retitle ID TITLE` verb, committed and published like every
other mutation.
