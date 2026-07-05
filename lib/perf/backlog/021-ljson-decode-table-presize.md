# 21. ljson.c decode builds every table with zero pre-sized slots

- status: done (2026-07-05)
- layer: cosmopolitan
- scenario: json_decode_large

- evidence: `json_decode_large` runs ~1.3ms/op and allocates ~375KB/op
  (see entry 7, which established that none of this is cosmic-wrapper
  overhead — `json.decode` is a two-line delegation). On the C side,
  `tool/net/ljson.c`'s `Parse()` creates both arrays (line ~243) and
  objects (line ~281) with `lua_newtable(L)` — zero pre-allocated
  array or hash slots — then fills them element by element with
  `lua_rawseti`/`lua_settable`. Lua grows tables by rehashing
  power-of-two steps, so a 1000-element array pays ~10 rehash/realloc
  cycles, and every object with 4+ keys pays hash-part growth.
- hypothesis: replacing `lua_newtable` with `lua_createtable(L, narr,
  nrec)` sized from a cheap lookahead (or even a fixed small guess
  like 8/8, which caps the worst case without measurable cost for
  tiny tables) cuts allocation churn and some portion of decode time
  for table-heavy documents. The scenario's ~375KB/op floor is the
  decoded graph itself and won't move; the rehash overhead on top of
  it is the target.
- how to test: the loop in `lib/perf/optimize/cosmopolitan.md` —
  change ljson.c in the whilp/cosmopolitan checkout, rebuild the
  local `lua`, `bin/make perf-bin`, then
  `PERF_BIN=o/perf/cosmic-local bin/make perf-compare` with a
  baseline taken from an unmodified local build (NOT the pinned
  binary — isolate your C change from unrelated pin drift).
- check: `json_decode_large`'s existing check() plus
  `bin/make test only=json` (run against the local binary via
  entry's perf-bin instructions) pin decode correctness; upstream,
  `tool/lua/test_cosmo.lua` exercises DecodeJson too.
- risk: medium — decoding is on the hot path of much real usage, and
  a bad narr/nrec guess wastes memory instead of saving time; measure
  alloc_kb as well as ns/op before keeping.
- result: done (whilp/cosmopolitan, tool/net/ljson.c). Replaced the two
  `lua_newtable(L)` in `Parse()` with `lua_createtable(L, 8, 0)` for
  arrays and `lua_createtable(L, 0, 8)` for objects — a fixed small
  guess (no lookahead) that covers the common short array / few-key
  object without a rehash. Correctness: empty-array `[]` and
  empty-object `{}` round-trips still hold, 9-key objects and 10-element
  arrays decode intact, and `o//tool/lua/test` (binding tests +
  definitions coverage ratchet) passes; DecodeJson's contract is
  unchanged so no `definitions.lua` / type regen needed. Measured via
  perf-bin A/B of two local default-mode builds differing only by the
  diff:
    json_decode_large   1.16 ms/op -> ~0.78 ms/op   ~-30%
    json_decode_small   1.08 µs/op -> ~0.74 µs/op   ~-31%
    json_roundtrip_small ~-16%; alloc unchanged (375 KB/op is the graph)
  The win reproduced on every one of ~8 runs. NOTE on measurement: this
  shared cloud runner is too noisy for the short syscall/fixed-overhead
  scenarios — `hash_sha256_small` and `startup_run_*` tripped the
  perf-compare regression bar, but a back-to-back controlled A/B
  (isolated, both builds ~identical) and an A/A control (the SAME
  unmodified binary vs its own baseline flags `hash_sha256_small`
  +10.5% and `startup_run_teal` +10.4%) proved those are pure runner
  variance, not the change (measurement.md's entry-11 situation). The
  end-to-end confirmation on the pinned release still happens at the
  cosmos bump per optimize/cosmopolitan.md.
