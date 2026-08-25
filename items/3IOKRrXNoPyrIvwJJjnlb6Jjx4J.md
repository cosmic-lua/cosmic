The http perf scenarios cover GET latency and bulk streaming and
stop there (2026-08-25 audit: http_bench.tl has http_fetch_get,
http_fetch_get_with_headers, and the http_tcp_roundtrip control;
download_bench.tl has http_stream_read_1mb). Three request shapes
the client serves have no scenario: (1) POST with a body — the
upload path through prepare() and the C client's request writer,
sized both small (form-shaped) and bulk (a 1 MiB body), with the
server echoing a digest so the check catches a corrupted upload;
(2) TLS on loopback — a forked HTTPS server with a self-signed CA
the scenario trusts, timing the handshake-dominated small fetch
(this is where TLS 1.2-only and no session reuse show up, and no
scenario observes TLS at all today); (3) a multi-request session —
N sequential fetches to one server in one scenario iteration, the
shape that makes per-request connection setup visible and is the
before/after instrument for the keep-alive hypothesis. Same
conventions as the existing modules: forked loopback child,
functional checks that fail on wrong bytes, scenarios registered so
_perf/run.tl sweeps them.
