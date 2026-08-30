## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port the JSONTestSuite and json.org
conformance corpus vendored in `test/tool/net/*.lua` into `tool/lua/`,
wired into `o//tool/lua/test`, so `cosmo.DecodeJson`'s adversarial
corpus coverage survives the lane's retirement (`3IOCgtWA`).

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root, and recorded in the inventory's `## Inventory`
table (`3ISCk9jyvgHUio3gPwQuZkSURUB`), rows for the 9 files below — all
`none`.

```text
wc -l test/tool/net/jsonorg_fail_test.lua test/tool/net/jsonorg_pass_test.lua \
      test/tool/net/jsontestsuite_fail1_test.lua test/tool/net/jsontestsuite_fail2_test.lua \
      test/tool/net/jsontestsuite_fail3_test.lua test/tool/net/jsontestsuite_fail4_test.lua \
      test/tool/net/jsontestsuite_okay_test.lua test/tool/net/jsontestsuite_pass_test.lua \
      test/tool/net/ljson_test.lua
#  187  100  437  188 5665  190  207  340  228  7542 total
```

`tool/lua/test_data_formats.lua` (288 lines) is the fork's only json
test and it is a CONTRACT test — array metatables, `NaN`/`Infinity`
rejection, empty-collection round-tripping, the `EncodeLua`
`literal=true` domain. It asserts nothing adversarial about the
*parser's* input handling. These 9 files are a different kind of
coverage entirely: the JSONTestSuite `y_`/`n_`/`i_` corpus (accept,
reject, implementation-defined) and the json.org `pass`/`fail` corpus,
plus `ljson_test.lua`'s own error-message vocabulary
(`"unexpected eof"`, `"object key must be string"`, ...), integer/float
overflow spelling, and UTF-16 surrogate-pair handling. None of that is
in `test_data_formats.lua` (`grep -c 'unexpected\|surrogate\|overflow'
tool/lua/test_data_formats.lua` is `0`).

None of the 9 files uses `require`; all call `DecodeJson` (and a few
`EncodeJson`/`EncodeLua`) as bare globals, plus `unix.pledge("stdio")`
once at the top. The fork registers the same functions under
`cosmo.DecodeJson`/`cosmo.EncodeJson`/`cosmo.EncodeLua` and
`cosmo.unix.pledge` (`require("cosmo")`, `require("cosmo.unix")`) — a
four-line prelude covers every call site in all 9 files, so the corpus
bodies move verbatim.

## Change

One `tool/lua/test_<name>.lua` per source file (a corpus this size does
not fit cosmic's own 500-line file-length convention, and `tool/lua/`
is not bound by it — but one file per source keeps each ported body a
direct, diffable copy of its origin, which is the point of vendoring a
corpus). Each new file opens with the same four-line prelude:

```lua
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local DecodeJson, EncodeJson, EncodeLua = cosmo.DecodeJson, cosmo.EncodeJson, cosmo.EncodeLua
```

(`unix.pledge(...)` call sites need no rebinding — they already read
`unix.pledge`, and `local unix = require("cosmo.unix")` makes that
resolve.)

| source | destination |
|---|---|
| `test/tool/net/jsonorg_fail_test.lua` | `tool/lua/test_jsonorg_fail.lua` |
| `test/tool/net/jsonorg_pass_test.lua` | `tool/lua/test_jsonorg_pass.lua` |
| `test/tool/net/jsontestsuite_fail1_test.lua` | `tool/lua/test_jsontestsuite_fail1.lua` |
| `test/tool/net/jsontestsuite_fail2_test.lua` | `tool/lua/test_jsontestsuite_fail2.lua` |
| `test/tool/net/jsontestsuite_fail3_test.lua` | `tool/lua/test_jsontestsuite_fail3.lua` |
| `test/tool/net/jsontestsuite_fail4_test.lua` | `tool/lua/test_jsontestsuite_fail4.lua` |
| `test/tool/net/jsontestsuite_okay_test.lua` | `tool/lua/test_jsontestsuite_okay.lua` |
| `test/tool/net/jsontestsuite_pass_test.lua` | `tool/lua/test_jsontestsuite_pass.lua` |
| `test/tool/net/ljson_test.lua` | `tool/lua/test_ljson.lua` |

Each gets its own three-line `tool/lua/BUILD.mk` rule, following the
existing shape at `tool/lua/BUILD.mk:222-251` exactly (e.g. for the
first):

```make
o/$(MODE)/tool/lua/test_jsonorg_fail.ok: o/$(MODE)/tool/lua/lua.dbg tool/lua/test_jsonorg_fail.lua
	$< tool/lua/test_jsonorg_fail.lua
	@touch $@
```

...and one new line per file added to the `TOOL_LUA_TESTS` list
(`tool/lua/BUILD.mk:222-251`), e.g.:

```make
	o/$(MODE)/tool/lua/test_jsonorg_fail.ok				\
```

No other file changes. `ljson_test.lua`'s `i_structure_500_nested_arrays`
case comment says spaces were added between `[[` and `]]` "so lua
doesn't get confused" — preserve that when copying the body; it is not
an artifact to clean up.

## Non-goals

- No binding change. `cosmo.DecodeJson`/`EncodeJson`/`EncodeLua` and
  their error strings are frozen; a corpus case that now disagrees with
  the fork's behavior is evidence for a *different* item, never a
  reason to edit `tool/net/definitions.lua` or the C here.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`. Retirement of
  the old lane is `3IOCgtWA`, blocked on the whole salvage container.
- Do not merge the 9 files into one. Each stays a direct, diffable copy
  of its origin under its own stamp.
- Do not re-run or re-measure the parent's pass/fail split; that
  evidence is settled in `3INxo51I`.

## Acceptance

From the repo root:

```text
make -j$(nproc) o//tool/lua/test
```

passes, and the stamp count is 9 higher than before this slice:

```text
grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk   # 38 (was 29)
```

Each new file's assertions are byte-for-byte the corpus body from its
source (`diff <(tail -n +N test/tool/net/<src>.lua) <(tail -n +4
tool/lua/test_<name>.lua)` shows only the header/prelude lines
differing — confirm per file). `git status --porcelain` in
cosmic-lua/cosmopolitan shows only the 9 new `tool/lua/test_*.lua`
files and the `tool/lua/BUILD.mk` diff.
