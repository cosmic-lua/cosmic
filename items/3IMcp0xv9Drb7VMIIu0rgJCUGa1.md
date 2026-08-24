# Problem

`-DSQLITE_ENABLE_DESERIALIZE` is already compiled in
(third_party/sqlite3/BUILD.mk:134) but lsqlite3 exposes no binding
for `sqlite3_deserialize`/`sqlite3_serialize`, so Lua cannot reach
it. The use case, verified blocked 2026-08-24: a cosmic artifact
embedding a `.db` as a zip member cannot open it in place — the
member must be extracted to a temp file first, because sqlite opens
by path and zipos paths are not seekable files. A
`db:deserialize(blob)` (or `open_memory(blob)`) binding would let
artifacts ship read-only databases opened straight from
`/zip/<name>.db` bytes with no filesystem step. Contract addition, so
per AGENTS.md it needs the tool/net/definitions.lua annotation in the
same commit and the annotation ratchet green (`make o//tool/lua/test`);
the typed cosmic-side wrapper (e.g. `sqlite.open_blob`) is a separate
follow-on slice on the cosmic repo once a release carries the binding.
