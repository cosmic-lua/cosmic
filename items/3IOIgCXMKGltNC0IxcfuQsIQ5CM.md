Every fetch request opens and closes its own connection: the client
sends `Connection: close` unconditionally (observed 2026-08-25 via a
loopback echo server — request headers are exactly Host, Connection:
close, User-Agent: cosmo-fetch/1.0), so a retry loop, a redirect
chain, and every call in a polling loop each pay TCP connect plus,
on https, a full TLS handshake (TLS is also capped at 1.2 in
lfetch.c, so no 1.3 one-RTT resumption). The hypothesis: per-process
connection reuse keyed by scheme+host+port — keep-alive with a small
idle pool in lfetch.c, or at minimum reuse across the hops of one
redirect chain and the attempts of one retry loop where the target
repeats. Measure with the _perf http/download scenarios against a
local server before and after; the optimize skill's compare gate is
the acceptance. Contract risk to respect: FetchStream readers borrow
the socket, so pooling must never hand a live streaming socket to a
second request.
