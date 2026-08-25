cosmic/fetch/init_example.tl covers GET, retry, and stream-lines
(2026-08-25 audit) and nothing else a first user reaches for: no
example shows the declarative body options (`json =`, `form =`,
`multipart` — the POST paths prepare() exists for), the verb helpers
(fetch.get/post/put/delete), download-to-file, or — the biggest gap
— branching on the structured error's `err.kind`, even though
AGENTS.md points at fetch as the worked example of structured
failures and the ErrorKind enum plus a `<total>` policy table is the
pattern users should copy. Add Example_* functions for each, in the
file's established shape: hermetic forked loopback servers,
deterministic `-- Output:` blocks, allow_private, check.must — so
each claim runs and verifies in CI via --make example. The err.kind
example needs no server at all: a connect refusal to 127.0.0.1:1
yields kind "connect" deterministically. Mind the 500-line cap:
init_example.tl is 116 lines; if the additions overflow it, a second
example file beside it follows the naming convention.
