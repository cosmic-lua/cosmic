# 29. json encoder's sorted path mallocs one buffer per object key

- status: done (2026-07-05)
- layer: cosmopolitan
- scenario: json_encode_large (and every sorted EncodeJson, which is
  the default)

- evidence: `json_encode_large` ran ~1.25 ms/op at cpu/wall 1.00 — pure
  CPU inside the C encoder, and *slower* than `json_decode_large`
  (~0.87 ms/op) even though decode has to build the whole Lua graph.
  A direct A/B on the raw local `lua` isolated the cost: encoding the
  1000-object payload with the default `sorted=true` took ~1290 µs/op
  vs ~920 µs/op with `sorted=false` — the sorted path adds ~370 µs/op
  (~28%). `EncodeJson` defaults to `sorted=true` (see `LuaEncodeSmth`
  in redbean.c / lcosmo.c), so cosmic's `json.encode` always pays it.
  Root cause in `third_party/lua/luaencodejsondata.c`'s
  `SerializeSorted`: for each string key it called `AppendStrList`,
  which `appendr`-allocates a fresh growable buffer per entry, then
  serialized `"key":value` into that buffer; after the loop it
  `qsort`ed the pointer array and concatenated. A k-key object paid
  ~k separate malloc/grow/free cycles plus the StrList pointer array.
- hypothesis: serialize every `"key":value` entry into ONE contiguous
  growable buffer, NUL-separated (`appendw(&ent, 0)` appends exactly
  one NUL), then build a pointer array into it and `qsort` with the
  same bytewise-strcmp comparator. This replaces k per-key mallocs
  with one `ent` buffer + one `ptrs` array, and — because the entry
  bytes and the comparator are unchanged — produces byte-for-byte
  identical output.
- how tested: the loop in `lib/perf/optimize/cosmopolitan.md`. Edited
  `SerializeSorted` in the whilp/cosmopolitan checkout, rebuilt the
  local `lua`, `perf-bin`, `perf-compare` vs a baseline from the
  unmodified local build.
- check: byte-identity fuzz — encoded tables with prefix-sharing keys,
  keys containing bytes < 0x22 (space, `!`), quotes, control chars,
  unicode, and deep nesting, under `sorted` / `sorted+pretty` /
  custom-indent, comparing the old vs new binary. All *sorted* output
  was byte-identical; the only diffs were on `sorted=false` output,
  which the old binary also differs from ITSELF across two runs (Lua
  5.4's randomized string-hash seed drives `lua_next` order) — proving
  those diffs are pre-existing nondeterminism, not the change. Plus
  `o//tool/lua/test` (binding tests + `definitions.lua` annotation
  ratchet) and cosmic `bin/make test only=json`, both pass. EncodeJson's
  contract is unchanged, so no `definitions.lua` edit / type regen.
- risk: low — one self-contained function; ordering is provably
  identical (same serialized bytes, same comparator, same NUL
  termination); no binding-contract surface touched.
- result: done (whilp/cosmopolitan, third_party/lua/luaencodejsondata.c).
  Direct A/B on the raw `lua` (best-of-8 × 3000, default sorted, the
  measurement that dodges scenario-wrapper + runner noise):
    encode 1000-object payload   ~1250 µs/op -> ~1130 µs/op   ~-10%
  reproduced on every repeat. End-to-end `perf-compare` showed
  `json_encode_large` 1.25 ms -> 1.19 ms (-5.2%, diluted into its
  ±10% noise bar) with 0 regressions across 33 scenarios. The
  `json_decode_large` +12.0% that perf-compare flagged is layout
  noise: `perf-selfcheck` (A/A, the modified binary vs itself) swings
  decode 851->867 µs at ±6–10% — decode code was not touched. The
  end-to-end confirmation on the pinned release happens at the cosmos
  bump per optimize/cosmopolitan.md.
