# 3. startup: Teal loader cost

- status: done (2026-07-04) — step (a) and step (b) both done
- layer: cosmic
- scenario: startup_run_lua, startup_run_teal

- result: `startup_run_lua`: 19.20ms -> 8.40ms..5.72ms across two
  re-measures (-56% to -70%). the whole `.lua`-vs-`.tl` gap this entry
  named turned out to be almost entirely step (a), not compilation
  itself: `startup_run_teal`/`startup_compile_teal` were essentially
  unchanged (still pay for loading the compiler, which they still need).
- evidence: `main.tl` called `require("tl").loader()` unconditionally
  at the top of EVERY invocation — even `--version`, `-e`, or running a
  plain `.lua` script — forcing Lua to load and execute the ~15k-line
  compiled `tl.lua` module every time.
- fix (step a): replaced the eager `require("tl").loader()` with a
  lazy searcher installed directly at the end of `package.searchers`.
  It only calls `require("tl")` (and installs the real
  `tl_package_loader`, replacing itself) the first time some
  `require()` call isn't resolved by an earlier searcher — i.e. the
  first time a `.tl`-only module is actually needed. Verified against
  `lib/cosmic/tl_loader_test.tl` (which asserts the searcher is present
  and not at position 2) and manually: plain `.lua` scripts, `-e`, and
  requiring a `.tl`-only module (falling back through the lazy
  searcher) all still work.
- risk note for step (a) that mattered in practice: the return type of
  a `package.searchers` element is itself a function type
  (`function(string): (function(string?, any?): any, any)`); writing
  that nested function-return-type inline as an explicit annotation
  compiles and type-checks fine but trips a bootstrap-compiler
  formatter bug (mis-indents everything after the declaration). Worked
  around by declaring the wrapper's return type as plain `any, any`
  and destructuring the real searcher's result into typed locals
  before returning them, instead of returning the call expression
  directly.
- result (step a): `bin/make perf-compare` from a clean re-baseline,
  confirmed on a second re-measure: 20 scenarios, 0 regression, 1-2
  faster (`startup_run_lua`), 18-19 ok.
- fix (step b): added `lib/cosmic/script_cache.tl`, a compiled-output
  cache used only by `load_script_file` (`main_handlers.tl`) — i.e.
  only `cosmic script.tl`, not `--compile`/`--check-types`/etc., which
  call `cosmic.teal` directly and are unaffected. Keyed on
  `script_path .. content .. build_id` (the running cosmic binary's
  version string, so a different build — possibly a different
  embedded Teal compiler — never reuses another build's cached
  output), hashed with `cosmic.hash.sha256_hex`. **Deliberately
  content-hashed, not mtime-based**: an mtime key (the original
  hypothesis's wording) risks a false cache hit if a script is
  rewritten within one filesystem mtime tick (coarse on some
  filesystems) — reading the small source file to hash it is cheap
  next to a full Teal compile, so there's no real reason to accept
  that risk. A failed compile (type or syntax error) is never cached,
  so error messages always reflect a fresh compile. Best-effort
  throughout: any cache read/write failure (missing dir, no write
  permission, a race with another process) is treated as a miss/no-op,
  never a hard error.
- added `test_script_cache_reuse_and_invalidation` to
  `lib/cosmic/script_test.tl`: runs a `.tl` script twice (same
  content, expects a cache hit the second time — verified indirectly,
  since correctness rather than hit/miss is what's asserted), then
  overwrites it with different content and confirms the new output
  wins (cache invalidation via content hash, not stale reuse).
- result (step b): `startup_run_teal` 27.91ms -> 6.55ms first pass
  (-76.5%), 7.59ms on re-measure (-72.8%) — now close to
  `startup_run_lua`'s own floor, as step (b)'s original hypothesis
  predicted. `startup_compile_teal` unaffected (within noise) both
  times, as expected since `--compile` bypasses the cache entirely.
  `bin/make perf-compare` both times: 22 scenarios, 0 regression,
  1 faster, 21 ok.
