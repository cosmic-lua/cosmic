# 21. ljson.c decode builds every table with zero pre-sized slots

- status: open
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
