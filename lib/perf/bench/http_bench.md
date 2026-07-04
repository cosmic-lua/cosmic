# http_bench

 HTTP client scenarios against a loopback server.
 A forked child serves fixed HTTP/1.1 responses on 127.0.0.1; the
 scenarios time the full client path: cosmic.fetch (the cosmo Fetch
 C binding) and a raw cosmic.net TCP round trip for comparison.
 The gap between the two is the fetch-layer overhead.
