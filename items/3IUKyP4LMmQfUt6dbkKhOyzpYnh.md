`pr.yml`'s `smoke` job runs five test files as BARE SCRIPTS — `./cosmic.exe
"$t"` over `cosmic/string_test.tl`, `cosmic/json_test.tl`,
`cosmic/fs/path_test.tl`, `cosmic/fs/path_normalize_test.tl` and
`cosmic/fs/path_windows_test.tl` (`.github/workflows/pr.yml:470-476`) — and
the direct-script path is the compile seam's one unsealed entry: `cosmic
foo_test.tl` goes `cosmic/searcher.tl:89` → `teal.compile_cached` →
`compile_file`, with no `_tool.seam` augmentation. Measured 2026-08-27 on
`origin/main` at `555873eb`: a runner-mode file whose single case is
`assert(false)` exits `0` under `o/bin/cosmic <file>_test.tl` having run
nothing, where its legacy counterpart exits `1` with the traceback. So once
the runner-mode migration reaches those five files — batch 3 (`3IU6AsZC`,
the three `cosmic/fs/path*` files), batch 6 (`3IU6BiCH`, `json_test.tl`) and
batch 7 (`3IU6BjUI`, `string_test.tl`) — the smoke lane keeps printing
`smoke: PASS` on real macOS and Windows runners while testing nothing, which
is precisely the portability signal the lane's own comment says it exists to
give ("a platform difference shows up as a named test rather than as a
mystery in a downstream project"). 3IU4umVT records this fifth seam entry
and assigns it to the migration container (`3IOCdooE`) but names no
consequence; this is the consequence, and it is a silent green, not a
failure. Two candidate fixes, both cheap: seal the direct-script path the
way the other three are sealed, or change the lane to `./cosmic.exe --make
test <the five paths>`. Batch 1 (`_build`, `_docs`, `_types`, `3p`, `_fuzz`,
`_eval`, `_perf`, `_tool`) is unaffected — `grep -rnE
'(cosmic|cosmic\.exe|bin/cosmic|o/bin/cosmic)[^|]*\b(_build|_docs|_types|3p|_fuzz|_eval|_perf|_tool)/[A-Za-z0-9_/]*_test\.tl'`
over `*.md`, `*.yml`, `*.mk`, `*.tl` and `*.sh` finds no bare-script
invocation of any file in its scope.
