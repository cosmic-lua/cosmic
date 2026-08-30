## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port `cosmo.FetchStream`'s malformed
chunked-transfer-encoding handling and SSE-style event-stream parsing
into `tool/lua/`, wired into `o//tool/lua/test`.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory row (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/lfetchstream_test.lua`, `none`, `covered by
tool/lua/test_fetch_local.lua` in part.

```text
wc -l test/tool/net/lfetchstream_test.lua
# 580
grep -c 'chunk\|sse' tool/lua/test_fetch_local.lua
# 1
```

`tool/lua/test_fetch_local.lua`'s streaming coverage is
`test_stream_no_empty_chunks` (one well-formed chunked response,
paced across writes) plus `test_stream_204_clean_eof` and
`test_read_until_lines`/`test_read_until_multibyte_and_mixing` — all
WELL-FORMED input. `lfetchstream_test.lua` is the only place that
exercises MALFORMED chunked framing: an invalid (non-hex) chunk size,
a missing trailing CRLF after chunk data, an incomplete final
terminator (`0\r\n` with no closing `\r\n`), and a chunk-size token
that overflows `size_t` — the reader must not hang or crash on any of
these, which is exactly the class of input a streaming HTTP client
handling untrusted origins needs proven. It is also the only place
that parses an SSE-style (`data: {...}\n\n`) event stream over
`FetchStream`, and the only place that tests content-length and
until-EOF (no `Content-Length`, connection close signals end) framing
for `FetchStream` specifically (`test_fetch_local.lua`'s equivalents
are all `Fetch`, not `FetchStream`).

The file self-preludes `FetchStream`/`ParseIp`/`unix`
(`local FetchStream = FetchStream or cosmo.FetchStream`, similarly for
`ParseIp` and `unix`), so it needs `require("cosmo")` in scope for
those `or` fallbacks to resolve, which it already has via
`local cosmo = require("cosmo")` at its own top. One test
(`test_stream_https`) reaches `httpbin.org/stream/3` over the real
network and already self-skips with a printed note when the network is
unavailable (`if not status then ... print("SKIP...") return end`) —
carry that guard as-is; it needs no policy decision the way the proxy
slice's httpbin tests do, since it degrades gracefully by construction.

## Change

One new file, `tool/lua/test_fetchstream_edge.lua`, copied from
`test/tool/net/lfetchstream_test.lua` verbatim (its self-prelude
already resolves under `require("cosmo")`/`require("cosmo.unix")`
being available — no additional aliasing needed beyond what the file
already does).

`tool/lua/BUILD.mk:222-251` gets one new three-line rule
(`o/$(MODE)/tool/lua/test_fetchstream_edge.ok: o/$(MODE)/tool/lua/lua.dbg
tool/lua/test_fetchstream_edge.lua`, run, `@touch $@`) and one new
`TOOL_LUA_TESTS` line.

## Non-goals

- No binding change. `cosmo.FetchStream`'s chunked-decoder behavior on
  malformed input and its error/EOF signaling are frozen. If a ported
  assertion no longer holds against the fork's real behavior (the
  malformed-input tests already accept more than one outcome, e.g.
  "nil with error, or empty result, but not a crash" — see
  `test_stream_chunked_invalid_size`), that is evidence, never a reason
  to touch `tool/net/lfetch.c`.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.
- Do not touch `tool/lua/test_fetch_local.lua`; this is a new file
  alongside it.
- Do not fold this into the Fetch-proxy slice
  (`titled "salvage cosmo.Fetch's HTTP-proxy contract..."`, filed
  alongside this one) — `Fetch` and `FetchStream` are independent
  surfaces even though both live in `tool/net/lfetch.c`.

## Acceptance

```text
make -j$(nproc) o//tool/lua/test
```

passes; stamp count is 1 higher than before this slice
(`grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk`).
`git status --porcelain` in cosmic-lua/cosmopolitan shows only the new
`tool/lua/test_fetchstream_edge.lua` file and the `tool/lua/BUILD.mk`
diff.
