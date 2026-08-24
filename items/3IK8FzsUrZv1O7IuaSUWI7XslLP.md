## Goal
G6 — the defining paths, ratcheted (this item's parent is the G6
container). Boot is a defining path: every `--make` child, every test
process, and every user artifact pays it. The stock Lua file searcher
probes each path template with `fopen`/`fclose` through
`package.searchpath` and then `luaL_loadfilex` reopens the winner, so
each of the ~15 boot modules is opened TWICE from `/zip`. A `/zip`
searcher that calls `loadfile` per template makes the load attempt BE
the probe: one zipos open per hit.

Evidence (research pass 2026-08-23, per `skills/optimize`, scouting
numbers — `os.clock`/shell loops, medians of 3+, not the `_perf`
gate): `--strace` of an empty script showed 33 `/zip` opens, 0 failed,
with 15 boot modules opened twice back-to-back; a rel-binary A/B over
2000 iterations ×2 measured `searchpath`+`loadfile` at 22.4–22.5 µs
against bare `loadfile` at 13.0–14.4 µs, i.e. 8.1–9.5 µs of probe
overhead per hit. 15 hits × ~8.8 µs ≈ 130 µs/exec ≈ 5.7% of
`startup_run_lua`. Those figures are the hypothesis, not the
acceptance; the harness decides (Acceptance below).

## Change
Three files. Tree facts measured 2026-08-24 at `9bcb0f7d` (`git log
--oneline -1`) with the commands quoted beside each.

**1. `cosmic/searcher.tl`** — `wc -l cosmic/searcher.tl` is 404 (96
lines of headroom under the 500-line cap); `grep -c install_zip
cosmic/searcher.tl` is 0.

Add a module-local `zip_searcher(module_name)` and a public
`install_zip()`, exported through the `SearcherModule` record
(`cosmic/searcher.tl:392-404`, beside `install`,
`install_argv_manifest`, `install_manifest`).

- `zip_searcher(name)`: `local rel = (name:gsub("%.", "/"))`, then for
  `"/zip/" .. rel .. ".lua"` and `"/zip/" .. rel .. "/init.lua"` in
  that order, call `loadfile(path)`; on the first non-nil chunk return
  `chunk, path` (the loader plus its loader-data filename, the same
  pair the default file searcher returns). On a miss return `""` — the
  EMPTY string, deliberately: a searcher must return a string, and the
  `/zip` templates stay in `package.path` (Non-goals), so the default
  file searcher still contributes the `no file '/zip/…'` lines and
  `require`'s aggregate error text stays exactly what it is today. Say
  that in the doc comment, with the second consequence: `loadfile`
  returns `nil, err` for a SYNTAX error too, so a corrupt module reads
  as a miss here and is then found, loaded and reported properly by
  the default file searcher one seat later — the fallback is what
  keeps the error honest.
- `install_zip()`: no return value, idempotent via a module-local
  `zip_installed` flag, plain no-op when `package.searchers` is nil —
  the same shape and guard as `install` (`cosmic/searcher.tl:130-136`),
  so its record entry is `install_zip: function()`. It does two things:
  1. **Dedupe `package.path`.** Split on `;`, drop every occurrence
     after the first of exactly `/zip/?.lua` and of exactly
     `/zip/?/init.lua`, rejoin. Only those two templates, and only
     exact-equal fields — no general dedupe of the path.
  2. **Seat the searcher.** `table.insert(package.searchers, 2,
     zip_searcher)` — after `package.preload`, ahead of the default
     file searcher.

**2. `cmd/cosmic/main.tl`** — `wc -l cmd/cosmic/main.tl` is 498, i.e.
2 lines of headroom, so this edit MUST pay for itself (Acceptance has
the bound). Keep the `package.path` splice at lines 12–14 exactly as
it is: it is the bootstrap that lets line 25's `require("cosmic.
searcher")` resolve at all, and `install_zip()`'s dedupe cleans up the
duplicate it creates. Add, immediately after `local searcher =
require("cosmic.searcher")` (line 25) and BEFORE
`searcher.install_argv_manifest(arg)` (line 27), a call to
`searcher.install_zip()` with a short comment. Order is the point:
seating `/zip` first means `install_manifest`'s insert-at-2
(`cosmic/searcher.tl:361`) pushes `/zip` to seat 3, so `--modules`
tree resolution keeps outranking the binary's payload. To stay under
the cap, rewrite the 6-line comment block at lines 6–11 (which
explains the `/zip`-ahead-of-`/zip/.lua/` ordering that
`install_zip`'s own doc comment now owns) down to at most 2 lines; any
equivalent trim in this file is fine — the Acceptance `wc -l` bound is
the contract.

**3. `cosmic/embed/init.tl`** — `wc -l cosmic/embed/init.tl` is 459
(41 lines of headroom). In `WRAP_MAIN` (lines 179–184), the generated
entry wrapper every artifact carries, replace
`require("cosmic.searcher").install()` with:

```
local searcher = require("cosmic.searcher")
searcher.install_zip()
searcher.install()
```

Leave the `package.path` prepend at line 180 (the wrapper's own
bootstrap, before `cosmic.searcher` is reachable) and leave
`WRAP_SENTINEL` at line 174 byte-identical — the sentinel is the
idempotence test for extract/embed roundtrips
(`cosmic/embed/init.tl:243`). This is the half that pays: `o/bin/
cosmic` is itself wrapped (`_make/artifact.tl:465` embeds through
`cosmic.embed.write`), so the wrapper is where the ~15 boot modules
are resolved.

**Tests** (all three files already exist; each new test is called on
the line after its `end`, per AGENTS.md):

- `cosmic/searcher_test.tl` (`wc -l` 97): a test that after
  `install_zip()` the searcher at index 2 returns a function and the
  path `/zip/cosmic/json.lua` for `"cosmic.json"`; a test that a
  repeat `install_zip()` does not grow `#package.searchers` (the
  idempotence shape already used at `cosmic/searcher_test.tl:84-87`);
  and a test that a miss returns a string.
- `cosmic/searcher_tree_test.tl` (`wc -l` 284): extend
  `test_install_lands_ahead_of_the_file_searcher` (line 115) or add a
  sibling asserting `package.searchers[2]` is the TREE searcher after
  `install_manifest`, with the zip searcher demoted behind it.
- `cosmic/embed_test.tl` (`wc -l` 401): a child-process assertion that
  in a built artifact each of `/zip/?.lua` and `/zip/?/init.lua`
  appears EXACTLY ONCE in `package.path` (today it is twice — `grep -rn
  "/zip/?.lua" --include=*.tl .` outside `o/` returns exactly the two
  prepend sites, `cosmic/embed/init.tl:180` and `cmd/cosmic/main.tl:14`,
  and a wrapped binary runs both).

## Non-goals
- **Do not remove the `/zip` templates from `package.path`.** Two
  readers depend on them and neither goes through `require`:
  `cosmic/teal.tl:20` (`package.searchpath("tl", package.path)` — the
  prove-tl-exists-without-loading-it check) and
  `_cli/require_hints.tl:20` (scans `package.path` templates with
  `io.open`). The searcher short-circuits ahead of them; introspection
  stays truthful.
- **Do not change resolution ORDER anywhere else.** The manifest tree
  searcher keeps seat 2 when installed (`cosmic/searcher.tl:361`), the
  cosmic `.tl` searcher stays last (`cosmic/searcher.tl:135`, pinned by
  `cosmic/tl_loader_test.tl`). Do not change
  `cosmic/tl_loader_test.tl`'s assertions; its index-2 probe returns a
  `.lua` path either way, so it passes unchanged — updating its comment
  wording is the only edit allowed there.
- **Do not touch `readable()` (`cosmic/searcher.tl:249`) or
  `tree_searcher`.** The in-project variant double-opens every tree hit
  through `io.open` + `load_built`; that is a separate mechanical
  follow-up, deliberately left here so this diff stays one hypothesis.
- **No new flags, no env knobs, no `cosmo.*` C-boundary change.** The
  `cosmo.*` contracts are frozen (AGENTS.md).
- Do not rename, delete, or weaken any `_perf` scenario or its
  `check()`; do not commit `o/perf/*.json`.
- Do not widen the diff to the `--modules`/manifest path, the strip
  floor, or `_make`.

## Acceptance
Run from the repo root. The build under test is the one this change
produces (`bin/cosmic --make build`, then `o/bin/cosmic` for the rest).

1. `bin/cosmic --make ci` ends with `ci: PASS`.
2. File caps hold — `wc -l cmd/cosmic/main.tl` is ≤ 500 (498 before
   this change), `wc -l cosmic/searcher.tl` is ≤ 500 (404 before), and
   `wc -l cosmic/embed/init.tl` is ≤ 500 (459 before).
3. `o/bin/cosmic --make test cosmic/searcher_test.tl
   cosmic/searcher_tree_test.tl cosmic/tl_loader_test.tl
   cosmic/embed_test.tl` passes, including the new tests named in
   Change.
4. `o/bin/cosmic --make example cosmic/searcher_example.tl` passes.
5. Performance, per `skills/optimize` (full suite, quiet machine,
   clean tree):
   - baseline the PRE-change build into `o/perf/baseline.json`
     (`git stash` or a second checkout at `9bcb0f7d`),
   - `o/bin/cosmic --make run _perf/run.tl --out o/perf/current.json`,
   - `o/bin/cosmic --make run _perf/gate.tl compare o/perf/baseline.json
     o/perf/current.json o/perf/selfb.json` ends with
     `perf-compare: PASS`.
   Quote the `startup_run_lua`, `startup_run_teal`,
   `startup_compile_teal` and `embed_run_startup` rows (before/after,
   with their ± spreads) in the PR description. The hypothesis predicts
   `startup_run_lua` improves by roughly 5%; if no startup scenario
   improves beyond its own ± spread, do NOT land a neutral boot-path
   change — append the measured numbers to this item's spec and end it
   as not planned (`skills/optimize` step 6).

## Enablement
none needed. Every predicted wrong turn is already caught by a command
in Acceptance: mis-ordering the install is caught by the
`searcher_tree_test.tl` seat assertion (3); dropping the `/zip`
templates from `package.path` is caught by `--make ci` (1) through
`cosmic/teal.tl:20`; overflowing `cmd/cosmic/main.tl`'s 2 lines of
headroom is caught by the `wc -l` bound (2) and by `--make lint` inside
`ci`; a neutral or regressing result is caught by the compare gate (5).
The APIs and conventions this touches are documented where the change
lands (`cosmic/searcher.tl`'s module header, AGENTS.md).
