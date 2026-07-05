# 10. net.parseip/formatip pure-Lua reimplementation

- status: done (2026-07-04)
- layer: cosmic
- scenario: net_ip_roundtrip

- result: `net_ip_roundtrip` (new): 864.0ns -> 115.3ns first pass
  (-86.3%), 118.5ns on re-measure (-86.7%)
- evidence: `net.parseip` (lib/cosmic/net.tl) did a `string.match`
  4-octet pattern, four `tonumber()` calls, and manual range checks;
  `net.formatip` did 4 bit-shifts plus `string.format`. Meanwhile
  `cosmo.ParseIp`/`cosmo.FormatIp` already existed and were already
  correctly used for the exact same job by the sibling module
  `lib/cosmic/ip.tl` — the same "unused sibling C binding" shape as
  the original `codec.decode_hex` fix, just in a different module.
- fix: delegated both functions directly. `cosmo.ParseIp` returns
  `-1` for invalid input (verified at runtime, matching its doc
  comment) rather than `nil, err`; `net_test.tl`'s
  `test_parseip_formatip` only asserts `ip == nil` for invalid/
  out-of-range input (never asserts specific error text), so mapping
  `-1` to the existing `"invalid IP address format"` message
  preserves every asserted behavior exactly.
- added `net_ip_roundtrip` to `lib/perf/bench/micro_bench.tl` (no
  scenario existed for `net.*` functions before this).
- result detail: `bin/make perf-compare` from a clean re-baseline,
  confirmed on a second re-measure: 23 scenarios, 0 regression,
  1 faster, 22 ok.
