## Goal

G4 — zero-config project gates: the coverage ratchet's denominator must
be a property of the file, not of which chunk spelling happened to
reach it first.

## Evidence

Measured 2026-08-22 at main `3d73d670`, after `bin/cosmic --make fetch
&& bin/cosmic --make build && bin/cosmic --make coverage` (which ends
`coverage: PASS (232 files)` and leaves 442 `.cov` files under
`o/.coverage/`).

**The two spellings coexist for the same module, in one run.**
`cosmic/codec.tl` is reached both ways:

```
$ grep -rl '@/zip/cosmic/codec\.lua' o/.coverage | wc -l
85
$ grep -rlE '@([^"]*/)?o/cosmic/codec\.lua' o/.coverage | wc -l
98
```

It is not one module. Mapping every distinct chunk spelling in that
run through `normalize`'s two branches, 70 display paths are reached
BOTH ways (`/zip/<m>.lua` and `o/<m>.lua`), 1 only via `/zip`
(`cosmic/searcher.tl`), and the rest only via `o/`.

**The two branches disagree about `parse`.** In
`_tool/coverage/report.tl`, the `/zip` branch returns `(source,
source)` (:108) and the `o/` branch returns `(source, p)` (:129) — so
one display path arrives with two different `parse` targets.
`merge_hits` (:214) keeps whichever parse created the entry first, over
a `pairs` walk of each `.cov` file's hits (:385). The reported total is
therefore a function of merge order, not of the file.

**The two parse targets have different executable-line sets.** A Teal
`local record R … end` is a type declaration in the `.tl` and a plain
`local R = {…}` assignment in the compiled `.lua`, so the compiled file
marks a line the source does not:

```
$ printf '%s\n' 'local l=require("_tool.coverage.lines")' \
    'local fs=require("cosmic.fs")' \
    'local function n(p) local e=l.executable_lines(fs.read(p),p) local c=0 for _,v in pairs(e) do if v then c=c+1 end end return c end' \
    'print(n(arg[1]), n(arg[2]))' > /tmp/n.lua
$ o/bin/cosmic /tmp/n.lua cosmic/fs/types.tl o/cosmic/fs/types.lua
51	52
$ o/bin/cosmic /tmp/n.lua cosmic/stream.tl o/cosmic/stream.lua
101	102
$ o/bin/cosmic /tmp/n.lua cosmic/_teal_ast.tl o/cosmic/_teal_ast.lua
30	31
```

Those three are the racing display paths whose sets differ today; the
other 67 agree, and `cosmic/searcher.tl`'s two spellings agree exactly
(symmetric difference 0). So the swing at main today is at most one
line on three rows — the mechanism is live and the payload is small,
which is the good moment to close it.

**Compiled line numbers are the coordinate system the hits are in.**
For 23 sources in the tree the compiler emits a hoisted require the
source does not have, shifting every later line by one — e.g.
`o/_eval/score.lua:40` is `local str = require("cosmic.string")`, which
`_eval/score.tl` does not contain, and 110 of that file's executable
line numbers move. Hits recorded from a compiled chunk are at compiled
line numbers, so the executable-line universe has to come from the
compiled file too, or the union inflates the total and the missing-line
list points at the wrong lines. This is why the rule below picks the
compiled artifact rather than the source, and it is what keeps the
report's numbers where they are today.

**Two claims in the item's own title and earlier evidence did not
survive re-measurement, and are out of scope below.** (1) `o/` never
holds a flattened `o/<pkg>.lua` for a directory module — the compiler
writes `o/cosmic/fs/init.lua`, whose `.tl` spelling exists, and the
flattened form appears only in the staged payload (`find o -maxdepth 4
-name fs.lua` returns `o/stage/cosmic/cosmic/fs.lua` only). Directory
modules reach the report from the `o/` side today: `cosmic/child/init.tl`,
`cosmic/coverage/init.tl` and `_cli/build/init.tl` are all in the racing
70. The `o/` branch therefore needs no `init.tl` fallback. (2) No chunk
under `o/stage/**` appears in a coverage run at all (`grep -c 'o/stage/'`
over the run's distinct chunk spellings is 0), so the staged payload is
not a third spelling in practice. (3) The 2026-08-21 note kept at the
foot of this spec — total 183 → 163 on `cosmic/string.tl` — was taken
on an unlanded branch and its mechanism does NOT reproduce at main: `covered`
fell by 22 in that measurement, and `covered` is the count of hit lines,
which no choice of `parse` can reduce. A separate capture carries that
hypothesis (module-level lines of a boot-loaded module executing before
the collector installs). Do not treat this slice as a fix for it.

## Change

Make `parse` a pure function of `display` in `_tool/coverage/report.tl`,
so no chunk spelling can influence it. Measured now: `wc -l <
_tool/coverage/report.tl` is 444 (56 lines of headroom under the
500-line cap) and `wc -l < _tool/coverage/report_test.tl` is 174.

1. Add one private helper beside `normalize`:

   ```teal
   --- The file whose text is analyzed for a display path's executable
   --- lines. Hits are recorded at compiled line numbers, so the
   --- universe comes from the compiled artifact when there is one.
   local function parse_for(display: string): string
   ```

   It returns `"o/" .. display:gsub("%.tl$", ".lua")` when `display`
   ends in `.tl` and that file exists (`fs.is_file`), and `display`
   otherwise. This is the rule the zero-hit fallback at :394 already
   applies inline; the change is that it now governs every entry.

2. Drop `normalize`'s second return. Its signature becomes
   `function(src: string, cwd: string): string | nil`, every branch
   returns the display path alone (the `/zip` branch at :108, the `o/`
   branch at :129, the direct-source branch at :133), and the
   `ReportModule` record (:431) and the `M` table (:439) follow.

3. `merge_hits` (:214) drops its `parse` parameter and sets
   `parse = parse_for(display)` when it creates the entry. Its caller
   (:386) becomes `local display = normalize(src, cwd)` /
   `merge_hits(entries, display, lines)`.

4. The `src_files` zero-hit loop (:393-:400) uses `parse_for(s)` in
   place of its inline `compiled` expression.

5. Keep `FileEntry.parse` — `analyze` still reads it — but it is now
   derived from `display` at the one point an entry is created, never
   chosen by whichever chunk arrived first.

In `_tool/coverage/report_test.tl`:

6. Update the four `normalize` tests that bind a second return
   (`test_normalize_maps_compiled_artifact_to_source`,
   `test_normalize_maps_embedded_directory_modules`,
   `test_normalize_maps_lua_only_source_with_no_tl`,
   `test_normalize_accepts_existing_tl_script`) to assert the single
   display return. Their display assertions do not change.

7. Add `test_denominator_is_independent_of_chunk_spelling`, which pins
   the property directly rather than trying to control merge order.
   Under `TEST_TMPDIR`, write a source `mod.tl` containing a `local
   record R … end` plus a couple of executable statements, and a
   compiled `o/mod.lua` whose corresponding line is a plain `local R =
   {}` assignment — so the two files' executable-line sets differ by
   that line, exactly as the measurement above shows for real modules.
   Write two `.cov` directories holding the SAME hit table, one under
   the chunk key `"@/zip/mod.lua"` and one under `"@o/mod.lua"`. With
   the cwd set to that tree, call `report.compute` on each directory
   and assert the `mod.tl` row's `total` is equal in both. Restore the
   cwd before asserting, as `test_normalize_maps_lua_only_source_with_no_tl`
   does.

## Non-goals

- Do not change what `analyze` computes (`total` is still the static
  executable lines unioned with the lines actually hit) or how `render`
  formats a row. Both are what the committed `.cosmic-coverage` floor
  is expressed in.
- Do not lower any floor. `.cosmic-coverage` is expected to need no
  regeneration at all; see Acceptance for the bound if it does.
- Do not add an `init.tl` fallback to the `o/` branch, and do not
  exclude `o/stage/**` — re-measurement above shows neither case
  occurs. If a future run proves otherwise, that is a new item.
- Do not attempt the boot-load hit-loss hypothesis from the
  2026-08-21 note, and do not touch `cosmic/instrument.tl`.
- Do not chase the remaining coordinate-system mismatch: a chunk
  recorded against a `.tl` source directly (a script run through
  `--make run` in a tree that also holds a compiled `o/<script>.lua`)
  will parse the compiled file under the new rule. That case does not
  arise in this repo's coverage runs — all 32 distinct `.tl` chunk
  spellings in the run measured above sit under `o/.coverage/**`
  (`grep -rho '@[^"]*\.tl' o/.coverage | sort -u`) and every one of them
  is already dropped by `is_excluded`. Narrowing it further is a new
  item, not this diff.
- Do not remove `FileEntry.parse`, and do not touch
  `_tool/coverage/lines.tl` or `_tool/coverage/baseline.tl`.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _tool/coverage/report_test.tl` passes,
  including `test_denominator_is_independent_of_chunk_spelling`.
- The new test fails before the fix and passes after it: quote both
  runs in the PR description.
- `normalize` declares one return:
  `grep -c 'normalize: function(src: string, cwd: string): string | nil$'
  _tool/coverage/report.tl` is 1 (it is 0 today — the declared type at
  :431 ends `string | nil, string`).
- `git diff -U0 .cosmic-coverage | grep -c '^[+-]  \["'` is 0. If it
  is not, the only rows permitted to move are `cosmic/fs/types.tl`,
  `cosmic/stream.tl` and `cosmic/_teal_ast.tl`, by at most one line
  each; regenerate with `bin/cosmic --make coverage --baseline`, quote
  the row diff in the PR description, and if any other row moves, stop
  and return the item to plan rather than committing the rewrite.
- `wc -l _tool/coverage/report.tl` is ≤ 500.

## Enablement

None needed. The rule this slice installs is stated as one helper with
one condition, the measurements above are re-runnable in seconds at
pull time, and the regression test is the countermeasure: the property
that was violated becomes a test the acceptance cites, which is
stronger than any note. The single-return `normalize` also brings the
function under the plain shape the `fallible-returns` rule describes (a
function whose first return admits nil returns at most two values), so
no lint moves against it.

## Prior evidence, kept for the trail

2026-08-20 audit at main `0b2907b9`, by reading. #1266 fixed the /zip
chunk normalization in `_tool/coverage/report.tl` (the /zip branch
returns `(source, source)`, :108) but the `o/` branch still returns
`(source, p)` (:129) — display `x.tl`, parse `o/x.lua`. One display
path can therefore still arrive via two spellings in one run
(`@o/cosmic/url.lua` and `@/zip/cosmic/url.lua`), and `merge_hits`
(:215) keeps whichever parse created the entry first over
nondeterministic `pairs` iteration (:385) — so if the compiled .lua
and the .tl have different executable-line sets, the reported total
still depends on merge order, contra the commit's "independent of
which .cov file wins the merge race". Pre-existing in the same
function: the o/ branch lacks the init.tl fallback the /zip branch
has, so a directory module reached via an `o/…/fs.lua` chunk is
dropped entirely. Not confirmed at runtime whether both spellings
coexist for one module in a CI run — measuring that is part of this
item.

2026-08-21, while implementing 3I7Otbvg at main `aaf4af95`. That change
makes `cosmic/instrument.tl` require `cosmic.string`, which puts
`cosmic.string` on the boot surface — every spawned child then loads it
from `/zip` as well as from `o/`. `bin/cosmic --make coverage` reported:

```
coverage ratchet: cosmic/string.tl: coverage declined 98.4% -> 96.9% (158/163, baseline 180/183)
```

The TOTAL moved 183 -> 163 while the source file GREW by 25 lines. The
two lines newly reported as missing were `local M: StringModule = {`
(:433) and `return M` (:456) — module-level statements that run on
every require. Reverting only the `instrument.tl` require removed the
ratchet complaint, which isolates the cause to the module becoming
boot-loaded.

The 2026-08-22 re-measurement above rules the parse race OUT as the
cause of that reading: `covered` fell by 22 there, and `covered` counts
hit lines, which no choice of `parse` can reduce. The live hypothesis
is that a boot-loaded module's top-level statements execute before the
collector installs its hook, so those lines are never recorded; the
`cosmic/fs/types.tl` row in today's report shows the same shape
(`missing: 3,5`, where :3 is the module's own `require`). That is a
separate item.
