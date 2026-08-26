## Capture

The narrow-pack-n tl patch (PR #1409, merged 2026-08-26 after the
06:00 UTC release cut) reaches builders only through the pin:
release.yml's next daily run builds a release whose checker knows
PackTable<any>, and bin/cosmic.pin must then move to it. Until that
bump, any cosmic/** change that NEEDS the new checker fails the cold
build's generation 1 (the pinned release compiles the tree first) —
the cold-build rule 3ISKgfS6 established.

Work: after the first post-2026-08-26 release publishes, bump
bin/cosmic.pin (url + sha256), run `bin/cosmic --make fetch` and
`bin/cosmic --make ci`, and land the bump as its own PR. Verify with
a probe that the pinned checker types `table.pack(...).n` as integer
over mixed args. Unblocks 3ISPGV8z (retire the coverage pack-n cast)
and any other patch-consuming cast retire.
