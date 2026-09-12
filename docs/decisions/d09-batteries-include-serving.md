# D9 — batteries include serving; not urgently

- **date:** 2026-07
- **status:** amended 2026-09 (D46 started the server story)
- **context:** the stdlib has an HTTP client, sockets, poll, and SSE
  parsing, but no server or concurrency model. upstream cosmopolitan
  had redbean; the fork was slimmed to the C core.
- **decision:** the battery test is "should a cosmic-built binary do
  this without shelling out or vendoring C" — which includes an HTTP(S)
  server and a concurrency story. direction, not deadline (G7).
- **rejected:** scripts-and-CLIs-only scope; letting eval findings
  alone set scope; freezing the surface.
- **consequences:** `net`/`poll`/`shm` designs should not paint the
  server story into a corner; no near-term delivery pressure.
- **amended 2026-09 (D46 starts the server half):** the server story
  has started — [D46](d46-http-engine-is-a-cosmo-binding.md) settles
  the HTTP engine as a `cosmo.http` binding over `net/http/`, surfaced
  as `cosmic.http`; the concurrency story stays open.

