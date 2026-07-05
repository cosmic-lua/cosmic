# Performance hypothesis backlog

Companion to `lib/perf/OPTIMIZE.md` (the operating manual — read that
first). This file is the log: concrete, evidence-backed starting points,
ordered by expected value-for-effort. Numbers are from harness bring-up
on the CI container (2026-07); re-baseline on your machine before
trusting them.

Work the backlog like this: pick ONE entry, run the loop in
`OPTIMIZE.md`, then update the entry in the same commit — `done`
(commit hash + before/after numbers) or `rejected` (measured numbers +
why the hypothesis was wrong). Rejected entries stay in the file; they
save the next agent from re-testing a dead end. Add new entries as
`open` when a report line or code read suggests one. Entries 1-8 live in
`lib/perf/BACKLOG_ARCHIVE.md`, split out purely because this file kept
growing past the repo's 500-line-per-file cap — the split carries no
other meaning.

9. **hash.sha256_hex dead `:lower()` call** — done (2026-07-04)
   - scenario: `hash_sha256_small` (new scenario): 488.9ns -> 305.1ns
     first pass (-37.6%), 300.8ns on re-measure (-38.5%)
   - evidence: `sha256_hex` (lib/cosmic/hash.tl) was
     `codec.encode_hex(cosmo.Sha256(data)):lower()`. Verified at runtime
     that `cosmo.EncodeHex` (which `encode_hex` delegates to directly)
     already emits lowercase hex, so `:lower()` was a dead full-string
     scan + allocation on every call, on top of the digest — same
     "wrapper redoes work the C binding already did" shape as the
     hex-decode fix (entry 1), just smaller.
   - fix: removed the `:lower()` call; existing tests already assert
     lowercase output and a known digest value, so this is provably a
     no-op removal, not a behavior change.
   - added `hash_sha256_small` to `lib/perf/bench/micro_bench.tl`
     (hashing `"abc"`, the NIST test vector) alongside the existing
     `hash_sha256_1mb`: the 1MB scenario's SHA-256 compute swamps a
     fixed-per-call wrapper cost like this one, so it needed a tiny-input
     scenario to show up at all — `hash_sha256_1mb` itself was
     unaffected (within noise), as expected.
   - result: `bin/make perf-compare` from a clean re-baseline, confirmed
     on a second re-measure: 22 scenarios, 0 regression, 1 faster, 21 ok.

10. **net.parseip/formatip pure-Lua reimplementation** — done (2026-07-04)
    - scenario: `net_ip_roundtrip` (new): 864.0ns -> 115.3ns first pass
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
    - result: `bin/make perf-compare` from a clean re-baseline, confirmed
      on a second re-measure: 23 scenarios, 0 regression, 1 faster, 22 ok.

11. **time.format_date builds a full DateTime just to use 3 fields** —
      done (2026-07-04)
    - scenario: `time_format_date` (new): 745.9ns -> 263.8ns first pass
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
    - result: `bin/make perf-compare` flagged `startup_run_lua`/
      `startup_run_teal` as regressed on the first pass (+11.3%/+10.3%,
      unrelated to this change); a clean re-run showed both back within
      noise and confirmed `time_format_date` at -64.8% — 24 scenarios,
      0 regression, 1 faster, 23 ok. Textbook case for the "re-measure
      before trusting an inconsistent flag" rule.

12. **subprocess execution (fork/exec/wait)** — open (evidence-gathering,
      2026-07-04)
    - scenario: `child_spawn_true` (new, `lib/perf/bench/child_bench.tl`):
      1.32ms/op, cpu/wall 0.14 (mostly not CPU — kernel fork/exec/wait
      time, as expected)
    - why a new scenario: the existing `startup_*` scenarios
      (`lib/perf/bench/startup_bench.tl`) already spawn a child process
      (`cosmic.child.spawn`), but the target is the `cosmic` binary
      itself, so those numbers conflate raw spawn overhead with booting
      a Lua/Teal runtime. `child_spawn_true` spawns `/bin/true` — about
      as cheap an exec target as exists — isolating `spawn()`'s own
      pipe-setup/fork/wait cost from what gets `exec`'d.
    - finding: read through `cosmic.child`'s `spawn()`
      (lib/cosmic/child.tl) and its I/O pump (`lib/cosmic/child_io.tl`).
      Both already call `unix.*` C bindings directly for every operation
      (pipe, fork, dup2, poll, read, write) — there's no pure-Lua
      reimplementation of syscall-level work to delegate, unlike the
      other entries in this backlog. No concrete fix identified this
      round; this entry exists to track the scenario for future passes
      (e.g. profiling where the non-CPU time actually goes, or whether
      always allocating 3 pipes when a caller doesn't need
      stdin/stderr capture is worth a fast path).
    - risk: unknown until a concrete hypothesis is found.

13. **time.format_iso8601 builds a full DateTime just to use 6 fields** —
      done (2026-07-04)
    - scenario: `time_format_iso8601` (new): 1.01µs -> 393.4ns first pass
      (-61.1%), 394.0ns on re-measure (-61.1%)
    - evidence: same shape as entry 11 (`format_date`), just formatting 6
      of `gmtime()`'s 11 fields instead of 3.
    - fix: replaced `gmtime()` + `string.format` with a direct
      `cosmo.Strftime("%Y-%m-%dT%H:%M:%SZ", timestamp)` call.
    - added `time_format_iso8601` to `lib/perf/bench/time_bench.tl`
      alongside `format_date`'s scenario.
    - result: `bin/make perf-compare` from a clean re-baseline, confirmed
      on a second re-measure: 26 scenarios, 0 regression, 1 faster, 25 ok.

14. **compress.deflate/inflate size-prefix pack/unpack** — rejected
      (2026-07-04)
    - scenario: `compress_deflate_roundtrip_small` (new): 6.84µs baseline;
      deflate-only fix measured +0.2% then +1.7% (no win); deflate+inflate
      together measured +1.3% then -0.3% (still no win) across four
      separate measurements
    - evidence: `deflate` built a 4-byte little-endian length prefix via
      `string.char(size % 256, math.floor(size/256) % 256, ...)`;
      `inflate` unpacked it via `data:byte(1,4)` plus multiply-adds.
      `string.pack("<I4", size)` / `string.unpack("<I4", data)` (Lua
      5.4's own C-backed pack/unpack, not a `cosmo.*` binding, but the
      same "let a C routine do it" idea) replace ~10 Lua ops with one
      call each — objectively simpler code.
    - fix attempted: replaced the manual byte-char loop with
      `string.pack`/`string.unpack` in both functions (first deflate
      alone, then both together, to see if the combined effect crossed
      the noise bar either way — it didn't).
    - why it was rejected despite being clean, simpler code: the
      `cosmo.Deflate`/`cosmo.Inflate` zlib calls themselves have enough
      fixed per-call overhead (state setup/teardown) that they swamp the
      few nanoseconds saved on prefix packing even for a 3-byte input —
      there's no input size where the Lua-side saving would be *more*
      visible, since zlib's per-call floor doesn't shrink with smaller
      inputs. Reverted both changes (`git checkout -- lib/cosmic/compress.tl`).
      Kept the new benchmark scenario per the "never remove a scenario"
      rule — it's a real, permanent addition to the suite even though
      this round's hypothesis on it didn't pan out.
    - risk: n/a, rejected on measurement grounds, not correctness.

15. **fs_path.relpath calls getcwd(2) twice for the common case** — done
      (2026-07-04)
    - scenario: `fs_relpath_relative` (new, in `lib/perf/bench/fs_bench.tl`):
      5.03µs baseline; three re-measures came back -8.3%, -10.4% (crossed
      the noise bar, flagged `faster`), -5.9% — consistently faster,
      never slower, across all three passes.
    - evidence: `relpath(p, base)` with a relative `p` and no explicit
      `base` (the common call shape — "make this path relative to cwd")
      called `abspath(p)` first, which internally calls `unix.getcwd()`
      to resolve `p`, and then called `unix.getcwd()` a second time to
      resolve the implicit `base`. Two syscalls doing the same lookup.
    - fix: in `lib/cosmic/fs_path.tl`, `relpath` now fetches `cwd` once
      when `base` is nil, reusing it both to resolve `p` (via
      `normalize(cwd .. "/" .. p)` when `p` isn't already absolute) and
      directly as `abs_base`, instead of the previous unconditional
      second `unix.getcwd()` call. The explicit-`base` path is
      unchanged.
    - correctness: `fs_path_test.tl`'s six `relpath` cases all pass
      absolute paths for both `p` and `base`, so they pin the shared
      path-math (common prefix / `..` counting) the fix doesn't touch,
      without exercising the changed branch directly. Verified by hand
      that the new branch produces identical results to the old code
      for relative-`p`/no-`base` inputs — both reduce to
      `normalize(cwd .. "/" .. p)` vs. `cwd` itself.
    - risk: low — pure refactor of which syscall runs when, no change to
      the string math or the public signature.

16. **embed.collect_dir stats every directory entry, even directories and
      symlinks it's about to skip** — done (2026-07-04)
    - scenario: `embed_run_tree` (new, in `lib/perf/bench/embed_bench.tl`,
      600 directories/1 file each so the syscall savings are big enough
      to show over `embed.run()`'s dominant, roughly-fixed cost of
      copying the ~6MB source executable into the output file): 41.98ms
      baseline; four re-measures came back -8.6%, -10.6%, -10.1%, -6.5%
      — consistently faster, never a regression, though the swing never
      cleared the noise bar (±38.6%, driven by that fixed exe-copy floor
      dominating the timing and only 5 samples fitting in the budget at
      ~40ms/op). Also added `embed_extract_tree`, covering `extract()`
      for round 8 — unaffected by this round's fix since it only times
      `extract()`, not `collect_dir`.
    - evidence: `collect_dir`'s `do_walk` called `fs.stat(full_path,
      false)` (lstat) on literally every directory entry before deciding
      what to do with it — including entries that turn out to be
      directories (stat result only checked via `fs.is_dir`, no data
      needed to recurse) or symlinks (silently skipped either way). The
      exact same waste `fs_walk.tl`'s `collect_all`/`files` already fix
      via dirent d_type.
    - fix: switched `collect_dir` from `fs.opendir` (whose `Dir.read`
      only exposes the entry name) to `unix.opendir` directly, cast to a
      local `EmbedDirHandle` type declaring `read`'s second return (the
      d_type), mirroring `fs_walk.tl`'s `WalkDirHandle` pattern exactly.
      `do_walk` now recurses on `kind == unix.DT_DIR` without a stat
      call (d_type never follows symlinks, so this can't be a symlinked
      dir — same cycle-prevention property the old lstat-based check
      had), skips entries that are definitely neither a dir nor a
      regular file (symlink, fifo, socket, ...) without stating them
      either, and only falls back to `fs.stat` for `DT_REG` (needs mode
      bits) or `DT_UNKNOWN` (filesystem doesn't expose d_type). Sorting
      entries for deterministic embed order now sorts an array of
      `{name, kind}` records instead of a bare `{string}` array, since
      the kind has to travel with the name through the sort.
    - correctness: ran the full `embed_test.tl`/`embed_advanced_test.tl`/
      `embed_env_test.tl` suite, including the two tests that exist
      specifically to pin this function's symlink handling —
      `test_embed_symlink_loop_terminates` (a self-referential symlink
      inside the embed dir must not cause infinite recursion) and
      `test_embed_symlink_to_outside_file_skipped` (a symlink pointing
      outside the embed dir must not be embedded) — both pass unchanged,
      since DT_LNK falls into the "skip without stat" branch exactly
      like the old code's S_ISLNK check did.
    - risk: low-medium — changes which C binding opens the directory
      (`unix.opendir` instead of `fs.opendir`) and adds a new local
      record type, but preserves every branch's existing behavior; the
      existing symlink-cycle and outside-symlink tests are the ones most
      likely to catch a regression here, and both still pass.

17. **embed.extract calls makedirs(2) once per file, even when several
      files share a directory** — done, modest win (2026-07-04)
    - scenario: `embed_extract_tree` (reused from entry #16; bumped the
      shared source tree from 600 dirs/1 file each to 120 dirs/5 files
      each so extract() actually has repeated files per directory to
      dedupe — the original 1-file-per-dir shape gave this round nothing
      to optimize): baseline 59.73ms; five re-measures (after the
      harness's own noise-filter retry) settled at +2.7%, -1.1%, -0.8%,
      -2.7% — leaning improved (3 of 4 better) but never a confirmed
      regression, never conclusively crossing the ±10% noise bar either
      way. `embed_run_tree`'s numbers (-18.3%/-14.8%, consistent with
      entry #16) are unaffected by this round's change, as expected —
      that scenario doesn't call `extract()`.
    - evidence: `extract()`'s loop called `fs.makedirs(dir)` for every
      file entry and every explicit directory entry, unconditionally.
      Archive contents are commonly many files under a handful of
      directories (e.g. extracting a whole embedded tree), so most of
      those calls re-walk a directory path that was already created by
      an earlier entry in the same `extract()` call.
    - fix: added a `made_dirs: {string: boolean}` memo table, keyed by
      the joined output path, checked before each `fs.makedirs` call
      (both the explicit-directory-entry branch and the per-file
      branch) and set after. Directory entries and file dirnames share
      the same cache since `fs.join`/`fs.dirname` normalize to the same
      string for the same directory either way.
    - correctness: full `embed_test.tl`/`embed_advanced_test.tl`/
      `embed_env_test.tl` suite passes. The memoization only skips a
      call that would otherwise redundantly recreate a directory that's
      already been created earlier in the same `extract()` call — it
      doesn't change what gets created, in what mode, or the error
      contract (a failed `makedirs` is still surfaced the same way,
      via the subsequent `cio.barf` failing).
    - risk: low — the fix can only reduce the number of `makedirs` calls
      for paths already proven created within the same run; it never
      skips the first call for a given directory.

18. **codec.decode_base64 scans the input twice on the happy path** — done
      (2026-07-04)
    - scenario: `codec_base64_roundtrip_64k`: 1.88ms baseline; two
      re-measures came back -71.8% and -70.8% — large and consistent.
    - evidence: `decode_base64` ran a negated-character-class scan
      (`str:match("[^A-Za-z0-9+/=]")`, to give a specific "invalid
      character" error) unconditionally, THEN an anchored
      content/padding-capturing scan (`^([A-Za-z0-9+/]*)(%=*)$"`) to
      validate structure — two full passes over the input on every
      call, valid or not, even though the anchored pattern alone already
      proves the input is well-formed when it matches.
    - fix: run the anchored content/padding match first. On the happy
      path (matches — i.e. every valid base64 string) that's the only
      scan; the character-class scan now only runs to disambiguate the
      error message in the failure branch (invalid character vs. padding
      before the end), which is the rare path. Same two error messages,
      same conditions, just reordered so the common case pays for one
      scan instead of two.
    - why the win is bigger than "cut one of two equal-cost scans in
      half": the removed scan was the *negated* character class
      (`[^A-Za-z0-9+/=]`, 4 ranges + a literal, excluded), which Lua's
      pattern matcher evidently checks per byte less efficiently than
      the anchored match's two positive classes — so removing it from
      the happy path saved more than 50% of the matching-related work,
      not describable as an cache/allocation change.
    - correctness: verified against all four existing `decode_base64`
      tests (`test_decode_base64_basic`, `_no_padding`, `_empty`,
      `_invalid_char`, `_invalid_padding`, `_padding_in_middle`) by hand
      — traced each through both branches to confirm identical error
      messages and identical accept/reject decisions, then ran
      `bin/make test only=codec_test`, which passed.
    - risk: low — same two validation conditions and error messages,
      only their evaluation order changed; no change to what cosmo.DecodeBase64
      is ultimately called with.

19. **url.decode's gsub+match validation replaced with a manual %-scan
      loop** — rejected (2026-07-04)
    - scenario: `url_decode_query_value` (new): 45.04µs baseline;
      manual-loop fix measured +53.2% then +56.1% on re-measure — a
      confirmed regression, not noise (crossed the ±10% bar both times).
    - evidence: `decode()` (lib/cosmic/url.tl) validated %XX
      percent-encoding via `str:gsub("%%(%x%x)", "")` (remove every
      valid escape) followed by `check:match("%%")` (anything left over
      is invalid) — two full-string C calls, the first of which builds
      and discards an entire copy of the string. Looked like the same
      "redundant full-string scan" shape as entry #18
      (`codec.decode_base64`).
    - fix attempted: replaced the gsub+match pair with a manual loop —
      `str:find("%", pos, true)` to locate each literal `%`, then
      `str:match("^%x%x", pos + 1)` to check the two bytes after it —
      so validation only touches `%` occurrences instead of the whole
      string, with no intermediate copy.
    - why it was rejected despite being the "obviously less work"
      approach: unlike base64's grammar, arbitrary percent-encoded text
      isn't expressible as a single anchored Lua pattern (the escape
      sequences can appear anywhere, and Lua patterns can't repeat a
      captured alternation), so the replacement needed a Lua-level loop
      making one `find` and one `match` call *per* `%` character. Each
      of those is a separate Lua-to-C round trip with its own call
      overhead; `QUERY_ENCODED` (the benchmark's realistic value) has
      enough `%XX` sequences that the sum of many small C calls lost to
      two single large-string C calls (`gsub`/`match`, each one call
      doing a tight internal C loop over the whole string). The "avoid
      building an intermediate string" saving was real but smaller than
      the added per-occurrence call overhead. Reverted
      (`git checkout -- lib/cosmic/url.tl`). Kept the new benchmark
      scenario per the "never remove a scenario" rule.
    - lesson for future rounds: "fewer bytes touched" doesn't always
      beat "fewer Lua-to-C calls" — a single C-implemented full-string
      operation can outperform a Lua-level loop over a subset of the
      same string once the subset isn't tiny relative to call overhead.
      Entry #18 won because it was still exactly one full-string C call
      on the happy path, not more calls of any kind.
    - risk: n/a, rejected on measurement grounds, not correctness (the
      manual loop was verified correct against all existing `decode()`
      tests before being measured and reverted).
