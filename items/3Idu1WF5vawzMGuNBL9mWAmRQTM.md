## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port `cosmo.Fetch`'s HTTP-proxy
contract — CONNECT tunneling, `Proxy-Authorization`, the `http_proxy`
env var, and proxy error handling — into `tool/lua/`, wired into
`o//tool/lua/test`. None of that is exercised anywhere in the fork
today.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory row (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/lfetch_test.lua`, `none`, `covered by
tool/lua/test_fetch_local.lua tool/lua/test_fetch_unix_proxy.lua` in
part.

```text
wc -l test/tool/net/lfetch_test.lua
# 1062
grep -c 'proxy' tool/lua/test_fetch_local.lua tool/lua/test_fetch_unix_proxy.lua
# tool/lua/test_fetch_local.lua:0
# tool/lua/test_fetch_unix_proxy.lua:14
```

`tool/lua/test_fetch_local.lua` covers SSRF blocking, redirects
(relative/absolute/303), opts-not-mutated, keepalive, and the failure
`kind` taxonomy (`connect`/`dns`/`timeout`/`too_large`/`protocol`/
`proxy`/`tls`) — all against loopback servers it starts itself, and it
never sets `opts.proxy`. `tool/lua/test_fetch_unix_proxy.lua` covers
only `unix://` SOCKET proxy PATH VALIDATION errors (missing path, too
long, not found, traversal) — never an actual `http://` PROXY
connection. `lfetch_test.lua`'s proxy block
(`test_proxy_connection_to_proxy` through
`test_proxy_auth_not_leaked_to_target`, ~20 self-contained tests using
a local TCP server it starts itself, no external network) is the ONLY
place in the fork that proves: a plain HTTP request through an
`http://` proxy actually connects to the PROXY and not the target; an
HTTPS request through a proxy sends `CONNECT host:443`; Basic
`Proxy-Authorization` is sent (and URL-decoded) for both plain and
CONNECT proxying, including long JWT-style passwords and
special-character passwords; a username-only proxy URL still sends
`user:` auth; an unauthenticated proxy URL sends NO
`Proxy-Authorization` header; proxy credentials never leak into a
plain `Authorization` header sent to the target; the `Host` header
still names the TARGET, not the proxy; and a bad/missing proxy
scheme, host, or unreachable proxy port each fail informatively.

The file ALSO carries ~20 tests against `httpbin.org` and `github.com`
(basic GET, redirects, status codes, custom headers, SSRF-blocked
private IPs, a known GitHub release-download redirect-header-length
regression). The parent's measurement (`3INxo51I`) found every one of
this file's inner failures in its sandbox reading
`badcert_not_trusted` — a re-terminated TLS egress in that specific
measuring environment, not a contract mismatch — so the file's content
is not in question, only whether this repo's own CI network policy
lets `o//tool/lua/test` reach the public internet. Resolving that is
this slice's own work, not a fact this item can assert in advance.

The file self-preludes `Fetch` (`local Fetch = Fetch or
require("cosmo").Fetch`) but calls `unix.*` and `ParseIp` bare.

## Change

One new file, `tool/lua/test_fetch_proxy.lua`, from
`test/tool/net/lfetch_test.lua`, with this prelude added above the
existing `local Fetch = Fetch or require("cosmo").Fetch` line:

```lua
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local ParseIp = cosmo.ParseIp
```

Split the body in two on the way over:

1. The proxy block plus the local-error-handling tests
   (`test_ssrf_blocks_*`, `test_invalid_scheme`, `test_bad_method`,
   `test_negative_maxresponse_rejected`) — all self-contained, no
   external network — land in `test_fetch_proxy.lua`'s `main()` test
   list.
2. The `httpbin.org`/`github.com` tests are NOT ported by this slice.
   They test real value (redirect-chain behavior, status-code mapping,
   a real regression against long `Location` headers) but need a
   verified network policy for `o//tool/lua/test` first — confirm
   whether `pr.yml`'s lane that builds/runs `o//tool/lua/test` has
   network access, and if not, whether a `SKIP`-on-no-network pattern
   (as `tool/lua/test_fetch_unix_proxy.lua`'s own header already notes:
   "Functional proxy tests require forking and may not work in all CI
   environments") is the fork's convention here. Land that as ITS OWN
   follow-up item once the policy is known, rather than guessing here.
   `test_response_too_large_error_message` belongs in THIS bucket, not
   in item 1: despite being one of `lfetch_test.lua`'s local-error-
   handling tests, its assertion path requires actually connecting to
   and reading a real response from `https://httpbin.org/get` —
   `tool/net/fetch.inc:688` enforces `maxresponse` only once bytes
   arrive on the wire — so it shares this bucket's network-policy
   blocker, not item 1's self-contained-and-ready status. It also
   carries a SECOND, independent blocker on top of that: even with
   network reachable, `tool/net/fetch.inc:696`'s
   `"response too large (max %I bytes)"` format string uses an
   unsupported `%I` conversion, so the byte count never renders and the
   test's `err:match("max %d+ bytes")` assertion never matches
   (tracked as its own item, `3IiEMurIlcpbXdQ9CUhYmGK2Sei`). Porting
   this test needs BOTH the network-policy follow-up above AND that
   format-string fix landed first.

## Non-goals

- No binding change. `cosmo.Fetch`'s proxy contract, `kind` taxonomy,
  and error strings are frozen. A proxy assertion that no longer holds
  is evidence, never a reason to touch `tool/net/lfetch.c` or
  `tool/net/definitions.lua`.
- Do not port the `httpbin.org`/`github.com` tests in this slice — see
  Change above. Filing that follow-up is this slice's job, not this
  slice's Acceptance.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.
- Do not touch `tool/lua/test_fetch_local.lua` or
  `test_fetch_unix_proxy.lua`; this is a new file alongside them.

## Acceptance

```text
make -j$(nproc) o//tool/lua/test
```

passes; stamp count is 1 higher than before this slice
(`grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk`).
`git status --porcelain` in cosmic-lua/cosmopolitan shows only the new
`tool/lua/test_fetch_proxy.lua` file and the `tool/lua/BUILD.mk` diff.
Every one of the ~20 proxy-block tests passes without reaching a
network beyond the loopback server the test itself starts.
