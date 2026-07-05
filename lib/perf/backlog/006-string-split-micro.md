# 6. string.split micro-costs

- status: done (2026-07-04)
- layer: cosmic
- scenario: string_split_csv

- result: 38.82µs -> 32.20µs (-17.0%, matching the 10-20% hypothesis)
- evidence: implementation already used plain `find`; remaining cost
  was `table.insert` (a C call resolving `#result` each time) and one
  `sub` per field.
- fix: replaced every `table.insert(result, ...)` with an explicit
  `n = n + 1; result[n] = ...` counter, in both the empty-separator
  (per-character) and normal-separator branches.
- result detail: `bin/make perf-compare`: 21 scenarios, 0 regression,
  1 faster, 20 ok. real user impact is small (this was a warm-up-scale
  item per the original hypothesis), but the win landed exactly where
  predicted with zero risk.
