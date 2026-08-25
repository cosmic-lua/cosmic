cosmo.Fetch cannot complete a HEAD request against an RFC-compliant
server. Measured 2026-08-25 (cosmic main a0c4ebd, pinned cosmos
2026.08.24): a loopback server answering HEAD with `HTTP/1.1 200 OK`
and `Content-Length: 5` and no body — the shape RFC 9110 §6.4.1
requires, advertising the entity length while sending nothing —
makes the client read for a body until EOF and return `protocol:
transport error` ("HTTP client EOF body error", fetch.inc:813). The
boundary is exact: HEAD with `Content-Length: 0` succeeds, and a 304
carrying a non-zero Content-Length succeeds (the bodiless rule is
applied for 304 but not for HEAD — fetch.inc references kHttpHead
only in its method validation). Fix in tool/net/fetch.inc: a HEAD
response is bodiless regardless of Content-Length, for both Fetch
and FetchStream (whose reader should return nil immediately).
Binding contract unchanged (no definitions.lua edit: same returns,
one more request shape that works); regression tests on the
cosmopolitan side, and on the cosmic side a loopback HEAD test in
cosmic/fetch plus, once green, a `fetch.head` verb helper beside
get/post/put/delete (its absence today tracks the broken method).
