Four observed fetch behaviors are undocumented, and each is one a
caller will reason about wrongly without the doc (measured
2026-08-25 at main a0c4ebd, loopback probes plus tool/net/lfetch.c):
(1) redirect method policy — a 303 rewrites to GET and drops the
body, while 301/302 re-send the original method AND body to the
redirect target (curl and browsers rewrite POST to GET on 301/302,
so this is the surprising-but-RFC-permitted choice); (2) a
cross-origin redirect strips Authorization and Cookie headers and an
HTTPS-to-HTTP redirect is refused with kind "blocked"
(lfetch.c:1304-1317) — good behavior nobody can rely on undocumented;
(3) setting `proxy` skips the SSRF private-address guard entirely
(lfetch.c:1020 checks `!proxyhost`), so allow_private is moot behind
a proxy — a safety-relevant fact the Options doc must state; (4) the
client sends no Accept-Encoding and does not decompress: an
unsolicited `Content-Encoding: gzip` body arrives as raw compressed
bytes with the header intact. All four land as doc-comment clauses
on fetch.Options/Response (served by --docs fetch), each backed by a
loopback test asserting the stated behavior so the claim is
executable — (1), (3) and (4) have no test today.
