Once the narrow-pack-n tl patch (item 3ISKgfS6) lands AND a cosmic
release carrying it becomes the pin (bin/cosmic.pin), the one pack-n
cast can come out: cosmic/coverage/init.tl:133
`return table.unpack(results, 2, results.n as integer)` returns to
`return table.unpack(results, 2, results.n)`, its two comment lines
(131-132) go, and the casts baseline row for the file drops 6 -> 5
via `bin/cosmic --make run _build/casts.tl --baseline`. It cannot
happen in 3ISKgfS6's own slice — measured 2026-08-26 at `b4ad036b`:
with the patch applied to o/3p and the cast removed,
`bin/cosmic --make build` fails generation 1 with
`cosmic/coverage/init.tl:131:46: error: argument 3: got <any type>,
expected number`, because the first generation compiles the tree with
the RUNNING binary's embedded (unpatched) tl, and CI's build/repro
lanes start from the pinned release the same way. The pull-time gate
for this item: `o/bootstrap/cosmic --check types` (or the pinned
release run any equivalent way) accepts a mixed table.pack `.n` used
as an integer — i.e. the pin has caught up. Same failure family as
board item 3IIm7ZyN.
