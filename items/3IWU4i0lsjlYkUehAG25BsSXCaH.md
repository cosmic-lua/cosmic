`_perf/gate.tl:200-202` ends the compare gate as soon as pass 2 reads
clean: a regression flagged in pass 1 that reads quiet against the
re-measured baseline exits 0 with TWO current-side samples, no A/A
control and no triage, while a regression that flags twice gets a third
sample and magnitude-aware triage across three control pairs. So a
borderline regression — one comparable in size to the machine's own
per-scenario noise — escapes on roughly the runs where its second sample
happens to read low, and `release.yml` re-baselines to the previous
release's BINARY daily, so the question is never re-asked: one escape is
absorbed into the ratchet permanently.

Measured on one container, 2026-08-28, from a worktree at
origin/main@6a4d0182: `bin/cosmic --make run _perf/gate.tl selfcheck
A.json B.json` over the full suite reports `48 scenarios: 12 regression,
2 faster, 34 ok, 0 noise, ...` — 14 of 48 scenarios move past the 10%
bar with the SAME binary measured twice back to back, up to +62.2%
(`re_split_colon_list`), +57.3% (`sqlite_point_query`), +32.9%
(`re_match_log_line`). A single quiet second sample is routine.

Deliberately NOT folded into 3IVL9t0P (the strike-twice re-key): that
slice re-keys `flagged_first` to the re-measured baseline and spends no
extra measurement, while fixing this asymmetry means buying measurement
passes inside a release step already carrying a 15-minute timeout —
a different change with a different cost. 3IVL9t0P states the asymmetry
in `_perf/gate.tl`'s header comment and leaves the sampling budget
alone. Options to weigh here: a third current-side pass when pass 2 is
quiet but pass 1 flagged; or reading the A/A control unconditionally and
triaging BOTH passes against it.
