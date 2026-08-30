## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port known-value correctness testing
for the `cosmo` encoding/escaping/URL/IP primitives into `tool/lua/`,
wired into `o//tool/lua/test`. `tool/lua/`'s only existing coverage of
this surface checks return TYPES, never VALUES.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory rows (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/base64_test.lua` (`none`, `covered by` `—`) and
`test/tool/net/lfuncs_test.lua` (`none`, `covered by
tool/lua/test_definitions_conformance.lua` in part).

```text
wc -l test/tool/net/base64_test.lua test/tool/net/lfuncs_test.lua
# 35  110  145 total
```

`tool/lua/test_definitions_conformance.lua`'s own header states its
scope precisely: "nothing verified that the annotated TYPES match
runtime behavior" — it calls each of `EncodeHex`, `DecodeBase32`
(with a probe value), `EscapeHtml`, `EscapeParam`, `UnescapeParam`,
`IsValidPercentEncoding`, `DecodeLatin1`, `EncodeLatin1`, `ParseUrl`,
`ParseIp`, `GetMonospaceWidth`, `IsPublicIp`, `IsPrivateIp`,
`IsLoopbackIp`, `FormatHttpDateTime`, `Crc32`, `Crc32c`, `Deflate`,
`Inflate` exactly ONCE each and asserts only that the RETURN SHAPE
matches its declared type in `tool/net/definitions.lua` — never that
the VALUE is correct. `lfuncs_test.lua` and `base64_test.lua` are the
only place any of these bindings' actual OUTPUT is checked against a
known-correct value: exact `EncodeBase32`/`DecodeBase32` results with
custom alphabets, `ParseUrl`'s full field decomposition of
`https://jart:pass@redbean.dev/2.0.html?x&y=z#frag` (scheme, user,
pass, host, path, query params, fragment — as a single structural
assertion, not per-field type-checks), `GetMonospaceWidth`'s CJK
double-width handling (`'ちち' == 4`), exact CRC32/CRC32c checksums
against the RFC-standard `"123456789"` test vector, exact
Deflate/Inflate byte output (raw and gzip framing), and the RFC 4648
base64 padding progression (`r`→`cg==`, `re`→`cmU=`, ...). None of that
is duplicated by the conformance probe, which by its own design only
ever calls each function with ONE throwaway input.

Neither file uses `require`; both call these functions and
`unix.pledge` as bare globals.

## Change

Two new files, both with the same prelude aliasing every bare name
they use to its `cosmo.*` binding (no submodule needed — all of these
are top-level `cosmo.*` functions):

```lua
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local EncodeBase64, DecodeBase64 = cosmo.EncodeBase64, cosmo.DecodeBase64
local EncodeHex, DecodeHex = cosmo.EncodeHex, cosmo.DecodeHex
local EncodeBase32, DecodeBase32 = cosmo.EncodeBase32, cosmo.DecodeBase32
local EscapeHtml, EscapeParam, UnescapeParam = cosmo.EscapeHtml, cosmo.EscapeParam, cosmo.UnescapeParam
local IsValidPercentEncoding = cosmo.IsValidPercentEncoding
local DecodeLatin1, EncodeLatin1 = cosmo.DecodeLatin1, cosmo.EncodeLatin1
local ParseUrl, ParseIp = cosmo.ParseUrl, cosmo.ParseIp
local GetMonospaceWidth = cosmo.GetMonospaceWidth
local IsPublicIp, IsPrivateIp, IsLoopbackIp = cosmo.IsPublicIp, cosmo.IsPrivateIp, cosmo.IsLoopbackIp
local FormatHttpDateTime = cosmo.FormatHttpDateTime
local Crc32, Crc32c = cosmo.Crc32, cosmo.Crc32c
local Deflate, Inflate = cosmo.Deflate, cosmo.Inflate
local EncodeLua = cosmo.EncodeLua
```

(`base64_test.lua` needs only the first line of aliases plus
`unix`; `lfuncs_test.lua` needs the rest.)

| source | destination |
|---|---|
| `test/tool/net/base64_test.lua` | `tool/lua/test_base64_vectors.lua` |
| `test/tool/net/lfuncs_test.lua` | `tool/lua/test_lfuncs_values.lua` |

`lfuncs_test.lua` also asserts `Compress == nil and Uncompress == nil`
(the deprecated pair the fork removed) — keep that assertion; it is a
live, still-true contract check, aliased as `local Compress, Uncompress
= cosmo.Compress, cosmo.Uncompress` in the prelude alongside the rest.

`tool/lua/BUILD.mk:222-251` gets two new three-line rules
(`o/$(MODE)/tool/lua/test_base64_vectors.ok: o/$(MODE)/tool/lua/lua.dbg
tool/lua/test_base64_vectors.lua`, run, `@touch $@`, and the equivalent
for `test_lfuncs_values`), and two new `TOOL_LUA_TESTS` lines.

## Non-goals

- No binding change. Every value asserted (CRC checksums, base64/base32
  vectors, deflate byte output) is a fact about the fork's CURRENT,
  frozen behavior; a mismatch is evidence to fix the ASSERTION to match
  reality, never the binding.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.
- Do not touch `tool/lua/test_definitions_conformance.lua`; this slice
  adds a second, complementary layer (value correctness) alongside its
  existing type-truthfulness layer, and does not replace it.

## Acceptance

```text
make -j$(nproc) o//tool/lua/test
```

passes; stamp count is 2 higher than before this slice
(`grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk`).
`git status --porcelain` in cosmic-lua/cosmopolitan shows only the 2 new
`tool/lua/test_*.lua` files and the `tool/lua/BUILD.mk` diff.
