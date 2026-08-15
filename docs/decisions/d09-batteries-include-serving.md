# D9 — batteries include serving; not urgently

- **date:** 2026-07
- **status:** active
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

