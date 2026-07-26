# 033 — minor cleanups: one item left

severity: low
type: cleanup
area: `cosmic/tar.tl`

## remaining

1. **`cosmic/tar.tl:247`** — `parse_pax` is exported but used only by
   tar's own tests. drop it from the return table (tests can exercise
   it through extraction fixtures) or record why it is public.

## resolved (944a352, 1ca5fd1) — for the record

stale floor comment, `driver.tl` `@return` block, `build_test` engine
comment, pr.yml `version.lua` comment, the fetch-skips-validation
sentence, the floor's prefix over-match (file entries now match
exactly, with tests), and the `write_if_changed` duplication. one item
was deliberately closed as won't-fix with the reason recorded at the
site: propagating `appender:remove()`'s error — the binding reports
"entry not found" (the normal fresh-embed case) through the same
channel as a real failure, so propagation broke every fresh embed;
distinguishing needs an `exists()` the binding does not offer.
