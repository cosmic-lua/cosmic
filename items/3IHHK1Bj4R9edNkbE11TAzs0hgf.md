## Goal
G5 — adversarial verification (this item's parent is the G5
container). cosmic's json fuzz slice found a silent round-trip loss in
the C encoder; fixing it at the source is what turns a fuzz finding
into a retired bound rather than a permanent workaround.

**This slice lands in whilp/cosmopolitan.** The spec below is the
issue body of whilp/cosmopolitan#265, re-measured against
`5bfcf79d` on 2026-08-24; the issue is the same work, and closing it
is part of the PR.

## Evidence
`EncodeJson` serializes a finite Lua float through `DoubleToJson`,
whose converter is built with `ToShortest` and decimal range
`[-6, 21)` and NO `EMIT_TRAILING_DECIMAL_POINT`
(`third_party/double-conversion/wrapper.cc:36-49`, re-read
2026-08-24) — so any integral-valued float below 1e21 prints as a bare
digit string. `DecodeJson`'s parser takes the integer path for a
digits-only token that fits int64 (`tool/net/ljson.c:216-237`, pushing
at `:236`), reaching the double path only on `.`, `e`/`E`, or int64
overflow (`ljson.c:225-231`). In `[2^53, ~1e17)` the double's exact
value is its own shortest spelling, so only `[~1e17, 2^63)` silently
changes VALUE — but every integral float loses its float-ness.

Reproduced 2026-08-24 against the released binary cosmic pins today
(`cosmos 2026.08.21-07fc94a1c`, whose `luaencodejsondata.c` is
byte-identical to master's):

    $ o/3p/cosmos/lua -e 'local c=require"cosmo"
      local x=1.775015055792255e18
      local b=c.DecodeJson(c.EncodeJson(x))
      print(c.EncodeJson(x), x==b, math.type(b))
      print(c.EncodeJson(0.0), c.EncodeJson(5.0), c.EncodeJson(1.5))'
    1775015055792255000	false	integer
    0	5	1.5

(run from a cosmic checkout after `bin/cosmic --make fetch`.)

Found by cosmic's json fuzz property (whilp/cosmic#1128, seed 1,
iteration 204); 901 of 2000 lossy samples in `10^[16,18]`, table in
that PR.

## Change
**The rule (settled upstream): a Lua float always encodes to a token
carrying `.` or an exponent.** Uniform — no band check, zero included
(`EncodeJson(0.0)` becomes `"0.0"`). A value-only fix would leave type
round-trips silently lossy and the rule unstatable in one sentence.

Four steps over six files in whilp/cosmopolitan (step 3's goldens
live in three files). Line numbers re-measured 2026-08-24 at
`5bfcf79d`.

1. `third_party/lua/luaencodejsondata.c`, `SerializeNumber` (lines
   60-82), float branch: after the `DoubleToJson` call (line 76), when
   the produced string contains none of `.`, `e`, `E`, append `.0`
   (`appends(buf, ".0")` beside the existing `appends`). The integer
   branch (`lua_isinteger`, lines 64-66) is untouched. `DoubleToJson`
   itself is untouched — its single caller is line 76, and
   `DoubleToLua`/`DoubleToEcmascript` are separate converters
   (`wrapper.cc:28` and `:51`).
2. `tool/lua/test_data_formats.lua` (245 lines; sections 1-4 at lines
   13, 55, 85, 143, `print("test_data_formats: PASS")` last at 245):
   add a **section 5** in the file's existing style — an
   `-----`-ruled `-- 5. <title>` banner, bare `assert(expr, "message")`
   lines, `cosmo` already required at line 10 — before the final
   `print`, and add its one-line summary to the header comment beside
   items 1-3. It asserts:
   - the minimal repro: `x = 1.775015055792255e18` round-trips with
     `x == back and math.type(back) == "float"`;
   - `2^53` and the `2^63` vicinity round-trip by value and type;
   - `cosmo.EncodeJson(5.0) == "5.0"` and
     `cosmo.EncodeJson(0.0) == "0.0"`;
   - integers unchanged: `cosmo.EncodeJson(5) == "5"`, and
     `math.maxinteger` round-trips as an integer.
3. Update the **seven** golden assertions the rule changes. This list
   is exhaustive — every `EncodeJson` equality assertion under `test/`,
   `tool/lua/` and `third_party/lua/` was enumerated 2026-08-24 with

       grep -rn "EncodeJson" test/ tool/lua/ third_party/lua/ \
         --include=*.lua | grep -E "==" | grep -v EncodeLua

   and the seven below are the only ones whose expected token is a
   float printed without `.` or an exponent (the rest are integers,
   strings, containers, error messages, or floats that already carry
   `.`/`e` such as `1e-12`, `3.14`, `1.5`, `2.718281828459045`,
   `-2.374623746732769e+47`):

   - `test/tool/net/ljson_test.lua:61` `'9223372036854776000'`
   - `test/tool/net/ljson_test.lua:62` `'-9223372036854776000'`
   - `test/tool/net/ljson_test.lua:63` `'9223372036854776000'`
     (all three → the same spelling with `.0` appended)
   - `test/tool/net/encodejson_test.lua:22` `EncodeJson(0.0) == "0"`
     → `"0.0"`
   - `test/tool/net/encodejson_test.lua:28`
     `EncodeJson(123.456e-789) == '0'` → `'0.0'`
   - `test/tool/net/jsontestsuite_okay_test.lua:176` `'[0]'` → `'[0.0]'`
   - `test/tool/net/jsontestsuite_okay_test.lua:207` `'[0]'` → `'[0.0]'`

   These run under the redbean suite (`test/tool/net/BUILD.mk`), which
   shares `LuaEncodeJsonData` — same commit, or that lane goes red.
   Neighbouring `EncodeLua` goldens (`ljson_test.lua:65`,
   `jsontestsuite_okay_test.lua:177`'s `'{0.}'`) do not move: a
   different converter produces them.
4. `tool/net/definitions.lua`, the `EncodeJson` doc block (lines
   2319-2408, `function cosmo.EncodeJson` at 2408): add one prose
   sentence — a float always encodes with a `.` or an exponent, so
   numbers round-trip by value AND by Lua number type. No
   `@param`/`@return` change, so the annotation ratchet is unaffected.

## Non-goals
- **No change to integer encoding or decoding.** The `lua_isinteger`
  branch and `ljson.c` both stay exactly as they are: an
  integer-shaped token in range IS an integer; the encoder simply
  stops producing such tokens for floats.
- **No change to `DoubleToLua` / `EncodeLua`.** Its `1000000.`
  goldens stay; it is a separate converter with its own flags.
- **No `EncodeJson` signature or option change.** No new option to
  select the old spelling, and no band check that would make the rule
  conditional.
- **Do not touch cosmic in this PR.** Retiring cosmic's `_fuzz`
  float bound needs a released cosmos pin carrying this fix, so it is
  a separate item under this parent, blocked on this one.
- The string-byte round-trip observation from cosmic (bytes above
  `0x7f` decode as UTF-8 pairs) is a different subject and is that
  module's stated contract, not a defect — do not touch
  `SerializeString` or the decoder's string path.
- No drive-by reformatting: the fork stays mergeable with upstream
  jart/cosmopolitan, so the diff is these four files and nothing else.

## Acceptance
Run from a whilp/cosmopolitan checkout on Linux with GNU make. The
first build downloads the cosmocc toolchain into `.cosmocc/`.

1. The Lua binding suite, including the new section 5 and the
   annotation ratchets:

       make -j$(nproc) o//tool/lua/test

2. The redbean suite carrying the goldens updated in step 3:

       make -j$(nproc) o//test/tool/net

3. The minimal repro through the built binary prints `true	float`
   (it prints `false	integer` today):

       make -j$(nproc) o//tool/lua/lua
       o//tool/lua/lua -e 'local c=require"cosmo"; local x=1.775015055792255e18; local b=c.DecodeJson(c.EncodeJson(x)); print(x==b, math.type(b))'

4. The spelling rule holds at the edges, and integers are untouched
   (prints `0.0	5.0	1.5	5	true`):

       o//tool/lua/lua -e 'local c=require"cosmo"; print(c.EncodeJson(0.0), c.EncodeJson(5.0), c.EncodeJson(1.5), c.EncodeJson(5), math.type(c.DecodeJson(c.EncodeJson(math.maxinteger)))=="integer")'

5. Exactly these six files changed — the four `Change` steps, with
   step 3's goldens spread over three files — and nothing else:

       git diff --name-only origin/master
       # third_party/lua/luaencodejsondata.c
       # tool/lua/test_data_formats.lua
       # tool/net/definitions.lua
       # test/tool/net/encodejson_test.lua
       # test/tool/net/jsontestsuite_okay_test.lua
       # test/tool/net/ljson_test.lua

The PR closes whilp/cosmopolitan#265.

## Enablement
none needed. Every touched site is named with line numbers re-measured
2026-08-24 at `5bfcf79d`; the golden blast radius is enumerated
exhaustively with the grep that produced it; the test file's local
conventions (numbered `-----`-ruled sections, bare asserts with
messages, `require("cosmo")` at line 10) are stated; and the repro is
reproducible today against the pinned release before any build.
whilp/cosmopolitan is in this session's repository scope and builds
with plain GNU make per its AGENTS.md.
