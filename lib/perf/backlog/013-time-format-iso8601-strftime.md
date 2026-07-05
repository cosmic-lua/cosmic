# 13. time.format_iso8601 builds a full DateTime just to use 6 fields

- status: done (2026-07-04)
- layer: cosmic
- scenario: time_format_iso8601

- result: `time_format_iso8601` (new): 1.01µs -> 393.4ns first pass
  (-61.1%), 394.0ns on re-measure (-61.1%)
- evidence: same shape as entry 11 (`format_date`), just formatting 6
  of `gmtime()`'s 11 fields instead of 3.
- fix: replaced `gmtime()` + `string.format` with a direct
  `cosmo.Strftime("%Y-%m-%dT%H:%M:%SZ", timestamp)` call.
- added `time_format_iso8601` to `lib/perf/bench/time_bench.tl`
  alongside `format_date`'s scenario.
- result detail: `bin/make perf-compare` from a clean re-baseline,
  confirmed on a second re-measure: 26 scenarios, 0 regression,
  1 faster, 25 ok.
