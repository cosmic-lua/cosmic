# 11. time.format_date builds a full DateTime just to use 3 fields

- status: done (2026-07-04)
- layer: cosmic
- scenario: time_format_date

- result: `time_format_date` (new): 745.9ns -> 263.8ns first pass
  (-64.6%), 262.2ns on re-measure (-64.8%)
- evidence: `format_date` (lib/cosmic/time.tl) called `gmtime()` — a
  full `unix.gmtime` C call returning 11 fields (year, month, day,
  hour, min, sec, gmtoff, wday, yday, isdst, zone) plus a Lua table
  build for all of them — then formatted only 3 of the 11 fields via
  `string.format("%.4d-%.2d-%.2d", ...)`. `cosmo.Strftime` already
  existed and was unused for this. Verified `cosmo.Strftime("%Y-%m-%d",
  ts)` produces byte-identical output to the old code across epoch,
  Y2K, a modern date, year 1, and year 9999 (confirming `%Y`
  zero-pads to 4 digits the same way `%.4d` did).
- fix: replaced the `gmtime()` + `string.format` with a direct
  `cosmo.Strftime("%Y-%m-%d", timestamp)` call. `gmtime()`/`localtime()`
  themselves are untouched — other callers depend on the full
  `DateTime` record per their documented contract; only the one
  function that built a full record just to discard 8 of 11 fields
  changed.
- added a new `lib/perf/bench/time_bench.tl` (no scenario existed for
  any `time.*` function before this).
- result detail: `bin/make perf-compare` flagged `startup_run_lua`/
  `startup_run_teal` as regressed on the first pass (+11.3%/+10.3%,
  unrelated to this change); a clean re-run showed both back within
  noise and confirmed `time_format_date` at -64.8% — 24 scenarios,
  0 regression, 1 faster, 23 ok. Textbook case for the "re-measure
  before trusting an inconsistent flag" rule.
