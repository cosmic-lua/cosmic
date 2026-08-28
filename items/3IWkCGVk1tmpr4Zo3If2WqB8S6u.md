## Goal
G3 — an honest type layer, no escape hatches: a session that asks "is
this narrowing the carried patch or upstream tl?" must not get a
confident wrong answer from the tool.

## Problem (re-measured 2026-08-28 against `origin/main` = `37ea41cb`, `o/bin/cosmic` built 2026-08-28 14:49)

Three ways to ask "which checker answered". Two of them lie, silently.

The wrong form already documented (`3IVenbbU`, #1479): a modified
`tl.lua` on `package.path`. The `/zip` searcher outranks the file
searcher, so `require` loads the shipped copy.

The right form already documented (`3IWMDe1R`, #1482): `_make.patch`'s
`reverse`, which installs a de-patched copy in `package.loaded`.

The THIRD form is named nowhere, and it is the one a session reaches
for when it wants a verdict rather than a value: hand the snippet to
`cosmic --check types`. Re-verified today, verbatim:

    $ cat cli_probe.tl
    package.loaded["tl"] = dofile("/tmp/nonexistent-stock/tl.lua")

    local record R
      x: integer
    end
    local function make(): R | nil
      return nil
    end
    local r = make()
    if not r then
      return
    end
    print(r.x)

    $ o/bin/cosmic --check types cli_probe.tl
    Type check passed: cli_probe.tl
    exit=0

The `dofile` names a path that does not exist and would have thrown had
the line ever run. `--check types` never runs it: `handle_check_types`
(`_cli/main_handlers.tl:231-244`) reads the source, augments it through
`_tool.seam`, and hands the TEXT to `cosmic.teal.check`. The preload is
inert by construction, the shipped patched checker answers, and the
guarded index passes because that checker carries `narrow-truthiness`.

The in-process contrast, re-run today in one process against the same
snippet (`patch.reverse{pin = "3p/tl/tl_pin.tl", dir = "o/3p/tl",
entries = {"narrow-truthiness"}, file = "tl.lua", module_name = "tl"}`
then `cosmic.teal.check`, fingerprinting with
`debug.getinfo(require("tl").process_string, "S").source`):

    shipped   tl=@/zip/tl.lua   ok=true    errors=0
    reversed  tl=@<tmp>/patch-reverse-*/tl.lua   ok=false  errors=1
              cannot index key 'x' in variable 'r' of type R | nil

Same snippet, three forms, two of which report the opposite of the truth
with nothing logged.

Second facet, re-measured today: a bare `cosmic script.tl` resolves
`require("_make.patch")` to `@/zip/_make/patch.lua` — the binary's
EMBEDDED copy, even run from the repo root (verified with
`debug.getinfo(patch.reverse, "S").source`). Today's binary post-dates
#1482 so `reverse` is present, but a probe that means to exercise the
TREE's `_make/patch.tl` has to run under `cosmic --make run`.

## Change

Name the third form, and pin it with a test, in five places.

1. `docs/guides/checking.md` (406 lines today; `wc -l <
docs/guides/checking.md` = 406). Add one new `## Which Checker Answered`
section, placed immediately BEFORE the existing final section `##
Include Directories` (line 404; `grep -n "^## " docs/guides/checking.md`
lists `## Discarded Errors` at 365 and `## Include Directories` at 404).
It states, in this order:

   - `cosmic --check types` always answers from the Teal checker the
     RUNNING binary embeds, including cosmic's carried patch entries
     (`3p/tl/tl_patch/`).
   - It never executes the file it checks — `handle_check_types` reads
     the source and hands the text to `cosmic.teal.check` — so a
     `package.loaded["tl"]` or `package.preload["tl"]` assignment
     written inside the checked file never runs. Such a probe reports
     the shipped checker's verdict, at exit 0, with nothing logged.
   - A modified `tl.lua` placed on `package.path` is ignored for the
     same class of reason: the binary's `/zip` searcher outranks the
     file searcher.
   - To measure a DIFFERENT checker, swap it in the checking process
     before the first check: `_make.patch`'s `reverse` installs a
     de-patched copy into `package.loaded["tl"]`, which `require` reads
     before any searcher, and `cosmic.teal.check` then answers from it.
     The worked, gated recipe is `_make/patch_test.tl`'s
     `test_reverse_flips_the_checker_on_the_real_pin` and
     `test_reverse_flips_the_metatable_value_type` — copy those, do not
     re-derive them.
   - `debug.getinfo(require("tl").process_string, "S").source` names
     which bytes answered: `@/zip/tl.lua` is the shipped copy.
   - A probe script must run under `cosmic --make run` to load the
     tree's `_make/patch.tl`; a bare `cosmic script.tl` resolves
     `require("_make.patch")` to `@/zip/_make/patch.lua`.

   Every fenced block this section adds is tagged ```text or ```bash,
   never ```teal or ```lua. `_build/snippets_test.tl` compiles every
   ```teal/```lua fence under `docs/` with warnings-as-errors and
   asserts it is a formatter fixpoint; the probe recipe's real code
   already lives, gated, in `_make/patch_test.tl`, and a second copy in
   a guide would be a second thing to keep compiling.

2. `_make/patch.tl` (359 lines). Extend the existing "**Probing an
entry.**" doc-comment paragraph (lines 22-28) with one sentence naming
the third form: `cosmic --check types` on a file that preloads `tl` is
inert because the checker never runs the file, and pointing at `cosmic
--docs guide.checking`.

3-5. `3p/tl/tl_patch/ast_cache.tl` (175 lines), `closure.tl` (355),
`narrow.tl` (433 — 67 lines of headroom under the 500-line cap). Each
carries the same "Probing an entry:" plain-comment paragraph
(ast_cache.tl:19-24, closure.tl:53-58, narrow.tl:18-23; `grep -c
"Probing an entry"` = 1 in each). Add the same one sentence to each, so
the four copies stay identical.

6. `_cli/main_handlers_test.tl` (240 lines; 260 of headroom). Add one
test that pins the behaviour the guide now asserts, so the prose cannot
go stale silently: write a file under `TEST_TMPDIR` whose first line is
`package.loaded["tl"] = dofile("<a path under TEST_TMPDIR that does not
exist>")` followed by the guarded `R | nil` index above, run it through
the built binary with the file's existing `cli("--check", "types",
path)` helper, and assert exit 0 and that stdout contains `Type check
passed`. Name it
`test_check_types_ignores_a_preload_written_in_the_checked_file`.

   `_cli/main_handlers_test.tl` is a RUNNER-MODE file: measured today,
   `grep -c "^local function test_" _cli/main_handlers_test.tl` = 15 and
   `grep -c "^test_" _cli/main_handlers_test.tl` = 0. Define the new
   function and do NOT call it — a self-call would double-execute it
   under the runner. Verify only through `bin/cosmic --make test`; a
   bare `cosmic _cli/main_handlers_test.tl` is a silent no-op on a
   runner-mode file (`3IUKyP4L`).

7. `docs/design/nil-flow.md` (457 lines) — the narrowing census, and the
surface a session probing a narrowing rule reads first. Add one sentence
near its top pointing at `cosmic --docs guide.checking` for how to probe
which checker answered.

## Non-goals

- No mechanism that makes `--check types` honour a preload. It reads
  source text and never executes it; running the checked file inside the
  checker is a category change, not a fix.
- No warn-on-`package.loaded["tl"]` lint over checked sources. The
  pattern cannot separate a probe's preload from a legitimate in-process
  swap: `_make/patch_test.tl` assigns `package.loaded["tl"]` four times
  today (lines 271, 285, 314, 328) in a file that IS run, and
  `cosmic/teal.tl:19` reads it. A rule with a measured false positive in
  the tree is not a gate.
- Do not touch `cosmic/searcher.tl` (498 lines, `wc -l <
  cosmic/searcher.tl` = 498 — 2 lines of headroom). Its `/zip`-first
  precedence is deliberate and is not implicated here: `--check types`
  runs no searcher over the checked file at all.
- Do not change `_make/patch.tl`'s `reverse` behaviour, its `Options`
  record, or `_make/patch_test.tl`'s existing assertions.
- Do not change the `Type check passed: <file>` line or `--check types`
  exit codes — `_cli/main_handlers_test.tl` and gate consumers parse
  them.
- Do not document script-vs-project `require` resolution in general;
  that is `3IK31i1L`. Say only the one sentence the probe needs.
- No `*_example.tl` for the probe, and no new module: the recipe stays
  the one gated copy in `_make/patch_test.tl`.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _cli/main_handlers_test.tl` passes, including
  `test_check_types_ignores_a_preload_written_in_the_checked_file`.
- `grep -c "^test_" _cli/main_handlers_test.tl` = 0 (runner mode is
  preserved; it is 0 today).
- `grep -c "^local function test_" _cli/main_handlers_test.tl` = 16 (15
  today).
- `bin/cosmic --make test _build/snippets_test.tl` passes (no ```teal or
  ```lua fence was added to the guide).
- `bin/cosmic --make test _build/guides_test.tl` passes.
- `bin/cosmic --make test _make/patch_test.tl` passes unchanged — the
  recipe the guide points at still works.
- `bin/cosmic --docs guide.checking | grep -c "Which Checker Answered"`
  = 1 (0 today, so the section reaches the binary and not only the
  repo).
- `grep -c -- "--check types" _make/patch.tl` ≥ 1,
  `grep -c -- "--check types" 3p/tl/tl_patch/ast_cache.tl` ≥ 1,
  `grep -c -- "--check types" 3p/tl/tl_patch/closure.tl` ≥ 1,
  `grep -c -- "--check types" 3p/tl/tl_patch/narrow.tl` ≥ 1 (each is 0
  today).
- `grep -c "guide.checking" docs/design/nil-flow.md` ≥ 1 (0 today).
- `wc -l < 3p/tl/tl_patch/narrow.tl` ≤ 500 and `wc -l <
  docs/guides/checking.md` ≤ 500.

## Enablement

None needed as a blocker; the enablement IS this item's deliverable.
The check was run and recorded above:

- The strongest core countermeasure — a gate that refuses or warns on
  the wrong probe — was considered and rejected on measured evidence:
  the only detectable signal (`package.loaded["tl"]` in the checked
  source) has a real false positive in the tree today
  (`_make/patch_test.tl`, four sites). Recorded in `Non-goals` so a
  later session does not re-derive it.
- The next-strongest core move IS taken: item 6 turns the doc's central
  claim into a test the acceptance cites, so the prose cannot rot
  silently.
- The remainder is docs, and the sibling's lesson decides WHERE: a
  pointer in a file the prober does not open is the same failure one
  level over. The five surfaces above are where a session running a
  `--check types` probe actually looks — the shipped guide it reads
  first, the census it reads when the question is a narrowing rule, the
  patch module, and the three entry files.
- Conventions the implementing session needs are all in AGENTS.md plus
  the runner-mode note written into `Change` item 6.

## History

- `3IVenbbU` (#1479) — the `package.path` form, fixed.
- `3IWMDe1R` (#1482) — the pointer moved into the entry-file headers;
  `patch.reverse` added.
- This item is the third face: the `--check types` CLI form.

## Amendment — the Non-goals' false-positive measurement, re-measured

Added by session `0b13d2b4`, which held this item's claim while the spec
above was written. Nothing above is altered; this records one measurement
that bears on a decision the Non-goals make, so whoever builds this can
re-decide with it rather than discover it.

The second Non-goal rejects a warn-on-preload countermeasure because the
pattern "cannot separate a probe's preload from a legitimate in-process
swap", citing `_make/patch_test.tl` lines 271, 285, 314, 328 and
`cosmic/teal.tl:19` — "a rule with a measured false positive in the tree is
not a gate."

**That measurement does not survive two restrictions the probe form allows:
column 1, and assignment rather than read.** A probe's preload is by
construction a top-level statement; the cited sites are neither.

```
$ grep -rn --include=*.tl -E '^package\.(loaded|preload)' . | grep -v '^\./o/' | wc -l
0
$ grep -rn --include=*.tl -E '^[[:space:]]*package\.(loaded|preload)[^=]*=[^=]' . | grep -v '^\./o/' | wc -l
14
$ grep -rn --include=*.tl -E '^[[:space:]]*package\.(loaded|preload)[^=]*=[^=]' . | grep -v '^\./o/' | sed 's|:.*||' | sort | uniq -c
      1 ./_make/patch.tl
      5 ./_make/patch_test.tl
      8 ./_perf/run_test.tl
```

Zero sites in the tree assign `package.loaded`/`package.preload` at column 1.
All 14 are indented inside function bodies. The four sites the Non-goal names
are at column 3, and two of them are READS, not assignments:

```
$ sed -n '271p;285p;314p;328p' _make/patch_test.tl
  local saved = package.loaded["tl"]
  package.loaded["tl"] = saved
  local saved = package.loaded["tl"]
  package.loaded["tl"] = saved
```

`cosmic/teal.tl:19` is likewise a read, in a condition:

```
$ sed -n '19p' cosmic/teal.tl
if not package.loaded["tl"] and not package.preload["tl"]
```

So a rule restricted to a column-1 ASSIGNMENT fires on nothing in the tree
today while still catching the filed reproduction. The false-positive count
is zero, not four.

**This does not overturn the Non-goal.** Cost, the boot surface, and whether a
stderr notice is worth a core change are all still live, and the shape
suggested by the analysis this came from — a token-exact `tl.lex` scan in
`handle_check_types`, exit code and stdout verdict untouched — carries an
enablement hazard: `_cli.main_handlers` is on the boot surface
(`_make/stamp.tl:59`), and `_make/stamp_test.tl`'s
`test_boot_list_covers_a_live_child` fails on any boot-loaded module
`BOOT_MODULES` does not name, so anything new it reaches must be required
lazily inside the function, as `cosmic.teal` and `_tool.seam` already are.

What is retracted is only the stated REASON: the measured false positive.
Whoever builds this should either re-reject the countermeasure on a reason
that holds, or take it.

## Cold-build rule — checked, does not apply

Neither this spec's shape nor the rejected alternative touches
`3p/tl/tl_patch/**` or the vendored checker, so no release-and-pin-bump
staging is owed. New `_cli` sources must still type-check under the pinned
checker in generation 1, and `_build/coldbuild_test.tl` already sweeps `_cli`
(its `--- reads:` line and `TREES` list both name it), so that guard is
automatic.
