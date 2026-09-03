## Evidence

The zbl9_M8VS builder spent ~10 minutes and 11 scratch files
(`/tmp/rectest1..11.tl`, 12 `--check types` runs) rediscovering that
`cosmic/sqlite/init.tl`'s `record Rows` and `cosmic/sqlite/row_iter.tl`'s
were nominally distinct despite identical fields, so the spec's "both
casts fall away for free" was false; the fix was the pattern
`cosmic/sqlite/bind.tl` already uses (`local type Rows = row_iter.Rows`
through a typed module record). `docs/guides/gotchas.md` has no entry
for nominal record identity (`grep -c nominal docs/guides/gotchas.md`
→ 0), and `docs/design/casts.md:363-368` ("incremental record
construction") describes the class without naming the alias pattern.

## Change

`docs/guides/gotchas.md`: one entry, "Records are nominal": two
declarations with the same fields are unrelated types; a module that
returns a record value declares the record once and exports it through
its module record (`type Rows = Rows`), importers alias it (`local
type Rows = mod.Rows`), never re-declare; `local x: R =
setmetatable({}, mt)` types the seed by the annotation, no cast. Cite
`cosmic/sqlite/bind.tl` as the worked example. `docs/design/casts.md`,
the incremental-record class: add the sentence "when the cast bridges
two same-shaped declarations, the fix is the alias, not the literal".

`_build/docs_test.tl` gates the guide's paths; no new test.

## Non-goals

No checker change; no census re-run.
