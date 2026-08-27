## Goal

G3 — an honest type layer, no escape hatches: the carried tl patch stops
documenting a capability it does not have. `narrow-metatable-helper`'s
`table_kinded` set (landed by 3ISSFrCO / PR #1439) lists `record` and
`interface`, but no `is` fact can ever carry those typenames, so the two
keys decide nothing — and that same spec's Non-goals stated the opposite
intent outright: "a nominal that merely resolves to some record must keep
failing". Delete the two dead keys, say what the helper really rescues,
and pin both halves in tests.

Deadness measured 2026-08-27 at main `267c2a4d`, three ways:

- `is X` builds its fact from `ub`, the UNRESOLVED type
  (`o/3p/tl/tl.lua:14118`,
  `node.known = IsFact({ var = node.e1.tk, typ = ub, w = node })`), so a
  named type arrives as `typename == "nominal"` and never matches
  `table_kinded`.
- A probe set driven through `cosmic.teal.check_file` answers
  `map_pos ok=true`, `array_pos ok=true`, `record_pos ok=false`,
  `interface_pos ok=false`, `scalar_neg ok=false`, and record/interface
  fail with `mt (of type metatable<<any type>>) can never be a Handler` /
  `... a Shape` — byte-identically under `o/bin/cosmic` (tree checker)
  and `o/bootstrap/cosmic` (pinned checker).
- A scratch clone with the two keys removed from the patch source, then
  `--make fetch` + a full `--make build`, answers the same probe set
  byte-identically and gates `ci: PASS (5 stages)`.

## Change

Two files, plus one build step.

**1. `3p/tl/tl_patch/narrow.tl`, entry `narrow-metatable-helper` only.**
Inside that entry's `replace` string:

- Change the single line (line 239 today)
  `      local table_kinded = { map = true, record = true, array = true, interface = true }`
  to
  `      local table_kinded = { map = true, array = true }`
  keeping the 6-space indentation the enclosing closure uses.
- Rewrite the carried-patch comment above it (lines 232-238 today) so it
  states what the helper can actually rescue: the is-fact carries the
  UNRESOLVED target type (`ub`), so a named type — a record, an
  interface, or a `type X = {string: any}` alias — arrives with
  `typename == "nominal"` and never reaches this set; only an inline
  `{K: V}` map or `{T}` array literal does. Keep the existing sentences
  about identity against `cache_std_metatable_type` and about `self`
  being passed explicitly; they are still true.
- Update the entry's `note` field to name an INLINE table-kinded
  is-target, e.g.
  `note = "recognize the std metatable<T> nominal against an inline table-kinded is-target"`.

Keep everything else in that entry byte-identical: the `find` anchor (it
anchors on `invalid_from`, which does not move), the `is_table_metatable`
body, and the `table_kinded` table itself — only its contents shrink, so
the two call sites keep compiling unchanged.

Measured 2026-08-27 at main `267c2a4d`:
`wc -l 3p/tl/tl_patch/narrow.tl` → `393` (107 under the 500-line cap);
`grep -c 'record = true' 3p/tl/tl_patch/narrow.tl` → `1`;
`grep -c 'interface = true' 3p/tl/tl_patch/narrow.tl` → `1`;
`grep -c 'table_kinded' 3p/tl/tl_patch/narrow.tl` → `2`;
`grep -c 'is_table_metatable' o/3p/tl/tl.lua` → `3`.

**2. `cosmic/teal_narrowing_test.tl`.** Add three tests after
`test_metatable_is_scalar_is_refused()`, which is the file's last
statement today (line 332). Write each in that file's existing shape:
`fs.write` a subject source into `TEST_TMPDIR`, `teal.check_file` it,
assert on `result.ok`, and call the function on the line after its `end`.

- `test_metatable_is_record_is_refused` — subject source declares
  `local record Handler` with a `name: string` field, then
  `local mt = getmetatable(x)` and `if mt is Handler then return mt.name end`.
  Assert `not result.ok` ("`mt is Handler` (a record nominal) must keep
  failing to check").
- `test_metatable_is_interface_is_refused` — the same with
  `local interface Shape` carrying `kind: string`, and `if mt is Shape`.
  Assert `not result.ok`.
- `test_metatable_is_array_narrows` — subject source is
  `local mt = getmetatable(x)`, `if not (mt is {string}) then return 0 end`,
  `return #mt`. Assert `result.ok`, building the failure text by
  concatenating `result.errors` messages exactly the way
  `test_metatable_is_table_narrows` (line 292) already does.

The first two pin the refusal the trimmed set now honestly describes;
the third pins the array half of the live rescue, which the file does
not cover today, so trimming the set cannot silently drop it.

Measured 2026-08-27: `wc -l cosmic/teal_narrowing_test.tl` → `332` (168
under the cap); `grep -c '^local function test_' cosmic/teal_narrowing_test.tl`
→ `11`; `grep -c '^local function test_metatable' cosmic/teal_narrowing_test.tl`
→ `2`. All three test bodies above were run verbatim on 2026-08-27 and
passed under `o/bin/cosmic`, under `o/bootstrap/cosmic`, and under a
scratch build with the keys already removed.

**3. Re-apply the patch before gating.** The change is patch DATA, so the
edit does not reach the checker until the pin is re-unpacked and
re-patched: run `bin/cosmic --make fetch` after editing
`3p/tl/tl_patch/narrow.tl`. Measured 2026-08-27 in a scratch clone with
`o/3p/tl/v0.24.8.tar.gz` already present: it prints
`unpack 3p/tl/v0.24.8.tar.gz` then `fetch: PASS (2 pins)` and downloads
nothing. Editing `o/3p/tl/tl.lua` directly is not the change — `fetch`
restores it from the pristine archive.

## Non-goals

- Do NOT make record, interface, or type-alias `is`-dispatch WORK. No
  `resolve_nominal` / `to_structural` call inside `is_table_metatable`,
  and no widening of the rescue past inline map and array literals.
  3ISSFrCO settled that a nominal resolving to a record must keep
  failing; reversing it is a new decision, not this slice. The fresh
  evidence for a future one — a named alias of a map is refused exactly
  like a record — is captured as 3IVSDpFq and must not be acted on here.
- Do NOT touch entries `narrow-metatable-is` or `narrow-metatable-not`,
  their `find`/`replace` strings, or the body of `is_table_metatable`.
  Only the `table_kinded` literal, the comment above it, and this entry's
  `note` move.
- Do NOT touch any other entry in `3p/tl/tl_patch/`. In particular leave
  the closure-carry narrow rule (3IVL3BLT) and the loop-site behaviour
  captured as 3IVQJa0b alone: this slice changes no live narrowing
  behaviour, in the tree or in any program.
- Do NOT change a `find` anchor anywhere in `3p/tl/tl_patch/`. An anchor
  must keep matching the pinned tl source exactly once; a pin bump that
  moves one is supposed to fail loudly, and that signal is not to be
  softened here.
- Do NOT touch `_make/patch.tl` or `_make/fetch.tl` (the mechanism is
  frozen), `3p/tl/tl_pin.tl`, or `bin/cosmic.pin`. No pin bump, no
  version change, no release staging.
- Do NOT delete, weaken, or reword the two existing metatable tests
  (`test_metatable_is_table_narrows`, `test_metatable_is_scalar_is_refused`,
  lines 287-332), and do NOT touch any other test in the file.
- Do NOT touch `cosmic/fs/types.tl` — the tree's one production metatable
  is-dispatch site (`mt is {string: any}`, line 248) — or any other
  product source. This slice adds no caller and removes none.
- Do NOT add docs or guide prose about metatable is-dispatch.
  `grep -rn 'table_kinded' docs/ AGENTS.md` → `0` hits today, and this
  slice leaves it at `0`; the patch entry's own comment is the
  documentation.
- Do NOT rewrite `3p/tl/tl_patch/narrow.tl`'s file header, split the
  file, or reformat unrelated entries.

## Acceptance

Run from the repo root. Every command below is safe to run verbatim and
writes only into `o/`.

1. `bin/cosmic --make fetch` ends `fetch: PASS (2 pins)` — the edited
   entry still applies exact-once to a freshly unpacked `tl.lua`.
2. `grep -c 'record = true\|interface = true' 3p/tl/tl_patch/narrow.tl`
   → `0`. It is `2` today.
3. `grep -n 'local table_kinded' o/3p/tl/tl.lua` prints exactly one line,
   reading `      local table_kinded = { map = true, array = true }` —
   proof the trimmed set actually reached the checker rather than only
   the patch source.
4. `grep -c 'is_table_metatable' o/3p/tl/tl.lua` → `3` (unchanged: one
   definition plus two call sites) — the helper was trimmed, not removed,
   and neither call site moved.
5. `bin/cosmic --make ci` ends `ci: PASS`.
6. `bin/cosmic --make test _build/coldbuild_test.tl` ends
   `test: PASS (1 file)` — generation 1's pinned checker still accepts
   the whole tree.
7. `bin/cosmic --make test cosmic/teal_narrowing_test.tl` ends
   `test: PASS (1 file)` and prints
   `✓ cosmic/teal_narrowing_test.tl (14 test functions)`. It is
   `(11 test functions)` today; the three new tests are the difference.
8. **The deadness proof.** `TEST_TMPDIR=$(mktemp -d) o/bootstrap/cosmic cosmic/teal_narrowing_test.tl; echo $?`
   → `0`. That runs the NEW test source under the PINNED release binary,
   whose embedded checker still carries `record` and `interface` in
   `table_kinded`. Identical verdicts from both checkers is what makes
   the keys dead rather than merely unused: no program the tests can
   express changes its answer when they go. (`o/bootstrap/cosmic` exists
   after any `--make build`; it is the pin `bin/cosmic` fetched.
   Measured 2026-08-27: all three new tests already pass there, before
   the change.)
9. `wc -l 3p/tl/tl_patch/narrow.tl` → at most `500` (`393` today);
   `wc -l cosmic/teal_narrowing_test.tl` → at most `500` (`332` today).
10. `git diff origin/main...HEAD --name-only` lists exactly two paths:
    `3p/tl/tl_patch/narrow.tl` and `cosmic/teal_narrowing_test.tl`.

## Enablement

`none needed` — no blocker item, no new mechanism, no pin bump. The
enablement check (simulate a literal-minded builder) predicted five
wrong turns; each is already caught by an Acceptance command or a
Non-goal, so no countermeasure needs its own item:

- editing `o/3p/tl/tl.lua` instead of the patch source → caught by 1 and
  3 (a `fetch` restores the file from the pristine archive, so a direct
  edit disappears);
- skipping `--make fetch`, leaving the checker unchanged and passing 5
  vacuously → caught by 3;
- helpfully adding nominal resolution so records dispatch → walled by
  Non-goals, with the reversal recorded against 3ISSFrCO and the evidence
  parked on 3IVSDpFq;
- deleting the whole helper rather than trimming its set → caught by 4;
- proving deadness by "ci still passes", which proves only that the tree
  does not use the keys → caught by 8, which compares two checkers that
  differ in exactly those keys.

**The cold-build rule does not bite.** Generation 1 compiles the whole
tree with the PINNED release's checker and patch set; `--make ci`
converges and re-judges with the checker the tree just built. Removing
these two keys changes no program's acceptance in either checker, so the
two generations still agree on every source — measured, not inferred:
the probe set answers identically under `o/bootstrap/cosmic` (keys
present) and under a scratch clone rebuilt with the keys removed
(`--make fetch`, `--make build`), and that scratch clone's full gate
ended `ci: PASS (5 stages)` on 2026-08-27. No staging behind a release
and pin bump is needed, and no source in this slice depends on a checker
rule: the three new tests write their subject source into `TEST_TMPDIR`
and check it at run time, so generation 1 type-checks
`cosmic/teal_narrowing_test.tl` itself under the pinned checker exactly
as it does today — the same reason 3ISSFrCO recorded when it added these
entries.
