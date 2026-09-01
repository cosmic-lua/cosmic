## Finding

`mWAm_RQTM`'s spec (`## Change`) lists `test_response_too_large_error_message`
among the tests to move into `test_fetch_proxy.lua`'s self-contained,
no-external-network group, alongside `test_ssrf_blocks_*`,
`test_invalid_scheme`, `test_bad_method`, `test_negative_maxresponse_rejected`.
That categorization is wrong: unlike those, this test's assertion path
requires actually connecting to and reading a real response from
`https://httpbin.org/get` — `tool/net/fetch.inc:688` enforces `maxresponse`
only once bytes arrive on the wire — so it cannot pass in `pr.yml`'s
loopback-only `ci` lane (per cosmic-lua/cosmopolitan's own AGENTS.md).

## Symptom

Porting the test as `mWAm_RQTM`'s spec currently instructs makes
`o//tool/lua/test` fail in CI (no network reachable), and even with network
reachable it fails anyway for an independent reason: `tool/net/fetch.inc:696`'s
`"response too large (max %I bytes)"` format string uses an unsupported `%I`
conversion, so the byte count never renders and
`err:match("max %d+ bytes")` never matches. Verified directly (transcript
from `mWAm_RQTM`'s builder run, real network reachable):

```text
$ o/tool/lua/lua.dbg /tmp/nettest2.lua
status	nil	err	response too large (max I bytes)
.../nettest2.lua:9: expected numeric byte limit in error message, got: response too large (max I bytes)
```

## Change

Amend `mWAm_RQTM`'s spec (`gitboard spec 3Idu1WF5vawzMGuNBL9mWAmRQTM`):
remove `test_response_too_large_error_message` from the self-contained group
that item ports, and fold it into the same "not ported by this slice, needs
a verified CI network policy first" bucket the spec already carries for the
`httpbin.org`/`github.com` tests. Note in that bucket that this specific test
also cannot pass until the `%I` format bug is fixed (sibling item, filed
separately) — two independent blockers, not one.

## Non-goals

- Not fixing the `%I` bug here — that is its own item, filed alongside this
  one under the same parent.
- Not deciding the CI network policy question — `mWAm_RQTM`'s spec already
  names that as its own follow-up; this item does not duplicate it.

## Acceptance

`mWAm_RQTM`'s spec, once amended, lists `test_response_too_large_error_message`
in its "not ported this slice" bucket rather than its self-contained group,
and the `test_fetch_proxy.lua` file that item's diff adds does not reference
that test.
