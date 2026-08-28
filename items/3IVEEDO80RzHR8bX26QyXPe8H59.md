## Goal

G6 — the defining paths, ratcheted: a compare report can be traced to
the WINDOW it was measured in, not only to the binary it measured.

Three review rounds on 3IU0GxoA were spent establishing, by hand, that
readings quoted side by side came from different measurement windows.
The report the reader holds says nothing about when either side was
measured, and the fact needed to say it is already written into every
results file. #1485 (3IUBNQZZ) landed the binary half of this — a
`binaries:` header above the rows. This is the session half, in the
same shape.

## Evidence (re-measured 2026-08-28, `origin/main` at `71e7d312`)

Every command below is quoted with its output and is runnable from the
repo root. Probes were run under the pinned bootstrap
`o/bootstrap/cosmic` (`bin/cosmic.pin` →
`145057b9fe905bb866fa3c03818265e4284a3bcd8367b76d9d5254f3c32a0900`),
which is the strictest available reader: the skew wall (fact 12) is
what that binary enforces.

**1. The stamp is written, once, and it dates the END of the run.**

```
git show origin/main:_perf/run.tl | grep -n 'timestamp'
```
→ `124:    timestamp = time.now(),` — the only match.

`time.now()` is declared `function(): integer, integer`
(`cosmic/time.tl:33`), and a table-constructor field takes the first
value, so `meta.timestamp` is whole seconds (probe:
`math.type((time.now()))` → `integer`). `collect_meta` is called at
`_perf/run.tl:280`, inside the payload constructor, AFTER the scenario
loop at `_perf/run.tl:250-268`. So the stamp is the moment the results
were WRITTEN, not the moment measurement began. The header this item
adds is labelled `measured:` to match that, and `perf_types` is
corrected to say so.

**2. The type already declares it, undocumented.**

```
git show origin/main:_perf/perf_types.tl | grep -n 'timestamp'
```
→ `49:    timestamp: number` — a bare field on `record Meta`, with no
doc comment, while the field beneath it (`bin_sha`, `:50-54`) carries
five lines of one.

**3. Nothing in the comparison half reads it, prints it, or checks it.**

```
git show origin/main:_perf/compare.tl | grep -n 'timestamp'
```
→ no matches (exit 1). So on `origin/main` today no report carries a
`measured:` line, which is what Acceptance 2 measures the change
against.

**4. `shape.into` does NOT drop the field.** The item's opening capture
asserted that `RESULTS_SPEC`'s silence makes `shape.into` DROP
`timestamp` "before any comparison code could read it". Measured, that
is false, and this spec is written on the corrected fact. **The item
TITLE still carries the wrong word** — no verb renames an item
(3IFWAdlL, band 1, backlog) — so read the title as the opening
hypothesis and this section as the fact.

```
git show origin/main:cosmic/shape.tl | sed -n '30,39p'
```
→ the frozen semantics: "extra keys a Spec does not name are IGNORED"
and "`into` returns the SAME table it was given, not a copy".

Probe (written to a scratch path outside the repo, run as
`o/bootstrap/cosmic <probe>.tl`), using `RESULTS_SPEC`'s exact shape as
it stands on `origin/main`:

```teal
local SPEC = shape.record({
    meta = shape.optional(shape.record({bin_sha = shape.optional(shape.string)})),
    results = shape.list(shape.record({
          name = shape.string, wall_ns = shape.optional(shape.number),
          spread_pct = shape.optional(shape.number),
          error = shape.optional(shape.string),
        })),
  })
local raw = [[{"meta":{"bin_sha":"abc","timestamp":1756305221},"results":[{"name":"x"}]}]]
local out = shape.into(json.decode(raw), SPEC)
```
→ `A: timestamp survives into(): 1756305221`

So the value survives `load_results` today, and because `pt.Meta`
declares the field (fact 2), `base.meta.timestamp` type-checks with
`RESULTS_SPEC` untouched. **Naming it in `RESULTS_SPEC` is therefore
not what makes it readable — it is what makes it VALIDATED**, and
fact 5 is why that matters.

**5. Unvalidated, a malformed file throws out of library code.**
`format_iso8601` is declared
`function(timestamp: integer): string | nil, string`
(`cosmic/time.tl:306`), so a `number` field must be floored at the call
site. `math.floor` on a non-number throws (same probe run):

→ `E: false  ...: bad argument #1 to 'floor' (number expected, got string)`

A results file carrying `"timestamp":"yesterday"` would reach that
throw from inside `compare.format` — a throw from library code, which
AGENTS.md forbids. Named in `RESULTS_SPEC`, the same file is refused by
`load_results` instead, on the error channel this module already has.
Probe, with `timestamp = shape.optional(shape.number)` added and the
payload carrying `"timestamp":"yesterday"`:

→ `B: refused: nil  meta.timestamp: expected number, got string`

and the two variants that settle `number` vs `integer` on a fractional
stamp (`1756305221.5`):

→ `C: integer vs fractional: nil  meta.timestamp: expected integer, got a fractional number`
→ `D: number vs fractional: true  nil`

`load_results` (`_perf/compare.tl:66`) wraps a shape error as
`<path>: not a perf results file (<shape error>)`. Verified live
against a real gate run over a fabricated file malformed in a way the
CURRENT spec already names:

```
gate.main("compare", "bad.json", "b.json", "selfb.json")
```
→ stderr `bad.json: not a perf results file (results[1].name: expected string, got number)`,
stdout `perf-compare: FAIL`, exit 1, no traceback.

`json.encode` writes the stamp with no space and as a bare integer
(probe: `{"meta":{"bin":"x","timestamp":1787948227}}`), and the
Acceptance 4 rewrite was run against a real results file:

```
sed -E 's/("timestamp":)[^,}]*/\1"yesterday"/' a.json
```
→ `...,"bin_sha":"1450...","timestamp":"yesterday"},"results":[...`

**6. The module's own docstring already states the rule this follows.**
`_perf/compare.tl:29-37`: "The fields perf.run also writes but nothing
here reads (iterations, samples_ns, cpu_ns, min_ns, max_ns, alloc_kb)
are left unnamed: `into` ignores keys a Spec does not name." A field
this module STARTS reading is therefore a field it names, and that
sentence has to be edited when the set changes.

**7. What is already landed, and is NOT this item's to add.**
`format_delta` (`_perf/compare.tl:237-251`) already prints BOTH
absolute levels — its format string is
`"%-28s %12s -> %12s  %8s  (noise %7s)  %s"`, base then current. This
item adds no level column and no per-row field.

**8. The blocker LANDED; this item composes on it.**

```
git show origin/main:_perf/compare.tl | grep -c format_identity
```
→ `5` (was `0` when this spec was first written). #1485 landed
`format_identity` (`_perf/compare.tl:268-279`), widened `format` to
`format(deltas: {pt.Delta}, base?: pt.Results, cur?: pt.Results)`
(`:292`), and added a file-local
`print_report(base_path, cur_path, deltas)` to `_perf/gate.tl`
(`:135-139`). `format`'s body already carries the header under a guard:

```teal
if base and cur then
  table.insert(lines, format_identity(base, cur))
end
```

so this item's `format` edit is one inserted line inside a guard that
already exists.

**9. The print sites COLLAPSED — the old "five call sites" figure is
dead.** #1485 funnelled every gate report through one function:

```
git show origin/main:_perf/gate.tl | grep -cn 'compare\.format('   # 1  (line 138, inside print_report)
git show origin/main:_perf/gate.tl | grep -n  'print_report('      # 135 def; 171, 253, 304, 344 calls
git show origin/main:_perf/run.tl  | grep -n  'compare\.format('   # 347
```

So there are exactly TWO `compare.format(` call sites in the tree and
both already pass `base, cur`. Nothing in this item's diff needs to
touch either, which is why `_perf/gate.tl` and `_perf/run.tl` are
Non-goals.

**10. Capacity, on `71e7d312`.**

```
for f in _perf/compare.tl _perf/compare_test.tl _perf/perf_types.tl _perf/gate.tl _perf/run.tl; do
  printf "%-24s %s\n" "$f" "$(git show origin/main:$f | wc -l)"; done
```
→ `_perf/compare.tl 399`, `_perf/compare_test.tl 360`,
`_perf/perf_types.tl 100`, `_perf/gate.tl 478`, `_perf/run.tl 394`.

**`_perf/gate.tl` is at 478 of the 500-line cap — 22 lines of
headroom — and this item does not touch it.** The header is produced
inside `compare.format`, which `gate.tl` already calls through
`print_report`; nothing lands in `gate.tl`. That constraint therefore
does not bind this item, and the code lands in `_perf/compare.tl`
(399, 101 lines of headroom).

Projected landing sizes, from the prototype in fact 11: `compare.tl`
gains ~65 lines (30 of code, ~22 of doc comment, ~13 of require, spec
entry, docstring edits and blanks) → **~464**, or **~481** if #1486
lands first (fact 13). `compare_test.tl` gains ~85 → **~445**.
`perf_types.tl` gains ~5 → **~105**. All three stay under the cap;
Acceptance 8 is the contract.

**11. The design was prototyped and type-checked under the pinned
bootstrap before this spec asserted it.** The exact code in `## Change`
was written to a scratch file and run through the same check
`_perf/skew_test.tl` performs (`--check types --include-dir <dir
holding only a _perf symlink>`, `COSMIC_COVERAGE=0`) using
`o/bootstrap/cosmic`:

→ `Type check passed` (exit 0, no warnings — and `--check types` fails
on any Teal warning).

Executed under the same binary, it printed exactly:

```
measured: base 2026-08-28T06:53:20Z  current 2026-08-28T15:26:55Z  (current +8h33m)
measured: base 2026-08-28T15:26:55Z  current 2026-08-28T06:53:20Z  (current -8h33m)
measured: base 2026-08-28T06:53:20Z  current unknown  (gap unknown)
measured: base unknown  current unknown  (gap unknown)
+12s	+2m	+8h33m	+0s	-8h33m
```

covering all four `measured:` states and all five `format_gap`
branches, including the zero gap an A/A selfcheck can produce.

**12. The skew wall is clear.** `_perf/skew_test.tl` requires every
non-test `_perf/**` file to type-check under `o/bootstrap/cosmic`. The
one new API this item reaches for is `cosmic.time.format_iso8601`, and
the pinned bootstrap has it:

```
o/bootstrap/cosmic <probe>.tl   # local s = time.format_iso8601(1756305221)
```
→ `iso: 2025-08-27T14:33:41Z  len: 20`, unchanged under
`TZ=America/Los_Angeles`. Fact 11's type check is the wall itself,
passed.

**Trap, closed here rather than at build time:** `format_iso8601`
returns TWO values (`string | nil, string`). Written inline as
`print("x", time.format_iso8601(t))` it spreads and fails with
`wrong number of arguments (given 2, expects at most 1)` — witnessed
while writing this spec. Assign it to a single-valued local first; the
`## Change` code does.

**13. #1486 (3IVLAF3Z) does NOT collide with this item.** It is open
against `_perf/compare.tl`, `_perf/gate.tl`, `_perf/gate_test.tl` and
a new `_perf/gate_identity_test.tl`:

```
gh pr view 1486 --json files --jq '.files[].path'
```

In `_perf/compare.tl` it adds `same_binary` AFTER `format`, edits
`identity_refusal`'s docstring and its stampless branch, and adds one
line each to the `compare` record and the `M` table. This item touches
the requires (`:13-17`), `RESULTS_SPEC` (`:29-48`), the region just
above `format` (`:255-291`), and `format`'s docstring and body
(`:281-316`) — all disjoint, and it adds nothing to the `compare`
record because both new functions are file-local. It does not touch
`_perf/gate.tl`, `_perf/gate_test.tl`, or `gate_identity_test.tl` at
all. **No `block` edge is warranted; either may land first.**

Two facts for whoever lands second: #1486's diff is cut against
PRE-#1485 `_perf/compare.tl` (its hunk context is the old
`local function format(deltas: {pt.Delta}): string`, which no longer
exists), so it must rebase onto `71e7d312` regardless of this item.
And #1486 takes `_perf/gate.tl` from 478 to ~490 — 10 lines of
headroom — which is #1486's constraint to carry, not this one's.

## Change

Three files, four edits. Name `timestamp` in `RESULTS_SPEC` so it is
validated, print one `measured:` header line beneath #1485's
`binaries:` line, and document what the stamp actually means.

**1. `_perf/perf_types.tl` — document the field (no type change).**
Above `timestamp: number` (`:49`), add a doc comment saying the stamp
is UNIX epoch seconds, UTC, recorded when the results file is written
— that is, at the END of the run, after every scenario has been
measured. Do not change the declared type: `number` is what a decoded
JSON value is, and narrowing it to `integer` would make `load_results`
reject a file whose stamp round-tripped as a float (Evidence 5, probes
C and D).

**2. `_perf/compare.tl` — validate the field.** In `RESULTS_SPEC`
(`:38-48`), add to the `meta` record, beside `bin_sha`:

```teal
timestamp = shape.optional(shape.number),
```

`optional`, because a results file written before this field existed,
or by a run that could not stamp itself, must still load — the same
reasoning `bin_sha` already carries. `shape.number`, not
`shape.integer`: `integer` REFUSES a fractional value (Evidence 5,
probe C), and a stamp that round-tripped through an encoder as
`1756305221.0` would turn a loadable file into a refused one. The
whole-seconds guarantee comes from `time.now()` at the WRITE side
(Evidence 1), not from the read side, and the call site floors anyway.

Then edit the `RESULTS_SPEC` docstring's "fields ... left unnamed"
sentence (`:35-37`) so its list no longer implies `timestamp` is one of
them, and say in one clause why this one is named: it is read by
`format_measured` below, so a non-number would throw downstream.

**3. `_perf/compare.tl` — the header line.** Add
`local time = require("cosmic.time")` to the module's requires
(`:13-17`; the module does not require it yet), then add these two
file-local functions immediately above `format`'s docstring (`:281`),
below `format_identity` (`:268-279`). This is the exact code that was
type-checked under the pinned bootstrap and executed (Evidence 11) —
build it as written, and give each function a doc comment in the house
form (`---`, `@param`, `@return`):

```teal
local function format_gap(secs: integer): string
  local sign = secs < 0 and "-" or "+"
  local a = secs < 0 and -secs or secs
  if a < 60 then return string.format("%s%ds", sign, a) end
  if a < 3600 then return string.format("%s%dm", sign, a // 60) end
  return string.format("%s%dh%02dm", sign, a // 3600, (a % 3600) // 60)
end

local function format_measured(base: pt.Results, cur: pt.Results): string
  local bt = base.meta and base.meta.timestamp
  local ct = cur.meta and cur.meta.timestamp
  local bs: string | nil
  local cs: string | nil
  local bi: integer
  local ci: integer
  if bt ~= nil then
    bi = math.floor(bt)
    bs = time.format_iso8601(bi)
  end
  if ct ~= nil then
    ci = math.floor(ct)
    cs = time.format_iso8601(ci)
  end
  local gap = "(gap unknown)"
  if bs ~= nil and cs ~= nil then
    gap = "(current " .. format_gap(ci - bi) .. ")"
  end
  return string.format("measured: base %s  current %s  %s",
    bs or "unknown", cs or "unknown", gap)
end
```

What that code decides, stated so a reader does not have to infer it:

- `format_gap` renders a signed gap in the largest unit that still
  answers "same window or not", deliberately dropping finer precision
  above a minute: `+12s` under a minute, `+2m` (floored) under an hour,
  `+8h33m` (`%s%dh%02dm`, floored) above.
- Each side renders through `time.format_iso8601`, which is UTC with a
  `Z` suffix and exactly 20 characters (Evidence 12).
- A side renders as the word `unknown` when its `meta` is absent, its
  `meta.timestamp` is absent, or `format_iso8601` returns nil.
  `unknown` is the same word `format_identity` uses for an unnamed
  binary, for the same reason.
- The parenthetical is `(current <gap>)`, signed against the base to
  match the `base -> current` direction `format_delta` already reads
  in, and `(gap unknown)` when EITHER side is `unknown`.
- `bt`/`ct` use the `base.meta and base.meta.timestamp` idiom
  `format_identity` already uses at `_perf/compare.tl:269-270`; the
  `~= nil` guard on the plain local is what narrows it before
  `math.floor`.
- Both are file-local and are NOT added to the `local record compare`
  block or the `M` table. They are reached only through `format`, the
  tests drive them that way, and keeping the exported record unwidened
  is what keeps this diff off `_perf/skew_test.tl`'s signature surface.

In `format` (`:292-316`), inside the `if base and cur then` guard that
already exists, insert one line after the `format_identity` insert:

```teal
table.insert(lines, format_measured(base, cur))
```

so `format(deltas)` with no identity arguments still returns
byte-identical text to today's. Extend `format`'s docstring
(`:281-291`) with one sentence naming the second header line.

**If `_perf/compare.tl` would exceed 500 lines** (projection is ~464,
or ~481 behind #1486 — Evidence 10), move `format_gap` and
`format_measured` unchanged into a new `_perf/report.tl` required by
`compare.tl`, and Acceptance 7's file list becomes four. Do NOT trim
doc comments to fit, and do not move `format_identity`.

**4. `_perf/compare_test.tl` — exactly five new test functions**, each
a `test_*` called on the line after its `end` (AGENTS.md), each driving
`compare.format(deltas, base, cur)` over hand-built `pt.Results` values
(no measurement). The file already has the helpers: `results(...)`,
`m(name, wall_ns, spread_pct)` (`:4-16`) and `sha_results(sha)`
(`:297-300`); add a stamped variant beside `sha_results` rather than
inlining literals five times. Their names, so Acceptance 5's count is
unambiguous:

- `test_format_measured_line` — both stamps present, current later by
  30815 seconds → the report's SECOND line is exactly
  `measured: base 2026-08-27T05:50:12Z  current 2026-08-27T14:23:47Z  (current +8h33m)`.
- `test_format_measured_negative_gap` — current EARLIER than base by
  the same 30815 seconds → the parenthetical is `(current -8h33m)`.
- `test_format_measured_gap_units` — three assertions, one per
  `format_gap` branch, read off the rendered line: a 12-second gap →
  `(current +12s)`, a 150-second gap → `(current +2m)`, a 30815-second
  gap → `(current +8h33m)`. (Verified: `30815 // 3600 = 8`,
  `(30815 % 3600) // 60 = 33`; Evidence 11 printed all three.)
- `test_format_measured_unknown_side` — `cur.meta.timestamp` absent →
  the line is
  `measured: base 2026-08-27T05:50:12Z  current unknown  (gap unknown)`.
- `test_format_without_identity_unchanged` — `compare.format(deltas)`
  with no identity arguments returns text containing neither
  `measured: ` nor `binaries: `.

Note for the builder: the three existing `test_format_identity_*` tests
(`:301-337`) assert with `text:find(..., 1, true) == 1`, i.e. that the
`binaries:` line is FIRST. They keep passing — `sha_results` carries no
timestamp, so those reports simply gain
`measured: base unknown  current unknown  (gap unknown)` as line 2. Do
not edit them.

## Non-goals

- **No new field in the results file.** `meta.timestamp` already exists
  (Evidence 1); nothing in `_perf/run.tl` changes. In particular, do
  NOT add a start-of-run stamp, a session id, a hostname, or a run
  uuid — the wall-clock stamp already on disk is the whole subject.
- **`_perf/run.tl` and `_perf/gate.tl` are not touched at all.** Both
  already reach the header through `compare.format` (Evidence 9).
  `_perf/gate.tl` is also at 478 of 500 (Evidence 10) — nothing may be
  added to it here.
- **No gap becomes a decision.** The `measured:` line is informational
  and may never refuse, warn, change an exit code, raise a bar, or feed
  `diff`/`triage`/`triage_many`/`loudest_control`.
  `DEFAULT_THRESHOLD_PCT` stays `10.0` and `TRIAGE_K` stays `2.0`
  (`_perf/compare.tl:19,27`). 3IU0GxoA's "What this does NOT license"
  binds: the 20-33% cross-session spread is NOT a noise budget, and the
  release lane measures baseline and candidate in the SAME job on the
  SAME runner.
- **`identity_refusal` is untouched** — its rule, its wording, and
  where `gate.tl` calls it. This item makes a fact VISIBLE; what the
  gate REFUSES on does not move. (#1486 is separately changing that
  function; do not merge, revert, or anticipate its change here.)
- **No per-row column and no second level field.** `format_delta`
  already prints both absolute levels (Evidence 7) and its format
  string is not edited.
- **No `format_identity` rewrite.** The `binaries:` line landed with
  #1485 and is consumed here as-is; this item adds a line beneath it
  and changes none of its text.
- **The exported `compare` record does not widen.** `format_gap` and
  `format_measured` stay file-local.
- **No history store, no derived per-scenario floor** — that is
  3IVDirCO's subject, and it is not opened here.
- No scenario, `check()`, or bench-module change; no codec row weakened
  or removed from any compare.
- Code comments carry no item ids, PR numbers, or dates
  (`skills/docs-style`).

## Acceptance

Run from the repo root, in order. `o/perf/` is build output and is
never committed.

1. **The repo gate.** `bin/cosmic --make ci` ends `ci: PASS`. This
   includes `_perf/skew_test.tl`, which type-checks every non-test
   `_perf` file under `o/bootstrap/cosmic` — the wall the new
   `cosmic.time` require has to clear (Evidence 12).

2. **The header prints live, with both stamps and a signed gap.** A
   one-scenario A/A through the real gate:

   ```
   bin/cosmic --make run _perf/gate.tl selfcheck o/perf/aa-a.json o/perf/aa-b.json --only codec_base64_roundtrip_64k > o/perf/selfcheck.txt
   grep -Eq '^measured: base [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z  current [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z  \(current \+([0-9]+s|[0-9]+m|[0-9]+h[0-9]{2}m)\)$' o/perf/selfcheck.txt
   grep -A1 '^binaries: ' o/perf/selfcheck.txt | sed -n 2p | grep -q '^measured: '
   ```

   Both greps exit 0 — the second pins the `measured:` line immediately
   below the `binaries:` line — and `tail -1 o/perf/selfcheck.txt` is
   still one of the two `perf-selfcheck:` lines the gate prints today
   (`_perf/gate.tl:346-350`), unchanged. On `origin/main` today the
   first grep exits 1: no `measured:` line exists (Evidence 3). The
   two selfcheck passes are seconds apart, so the gap renders in the
   `[0-9]+s` branch, `+0s` included (Evidence 11 printed `+0s`).

3. **Every gate report goes through the one call site this changed.**
   `gate.tl`'s four report prints all funnel through `print_report`,
   which holds the tree's only `compare.format(` call outside
   `run.tl`, so Acceptance 2 exercises the same line the `compare`
   mode prints:

   ```
   grep -c 'compare\.format(' _perf/gate.tl     # 1
   grep -c 'print_report(' _perf/gate.tl        # 5  (1 definition + 4 calls)
   grep -c 'compare\.format(' _perf/run.tl      # 1
   ```

   These are the counts on `origin/main` today (Evidence 9) and must be
   unchanged by this diff. A two-file `gate.tl compare` is deliberately
   NOT an acceptance command here: two `run.tl` passes over the same
   built binary produce the same `bin_sha`, and `gate_inner` refuses
   that pair before printing anything — reproduced live:
   `perf: a.json and same.json measured the SAME binary (145057b9fe90).`,
   exit 1, no report.

4. **A malformed stamp is refused at load, not thrown at format.**
   Using the real results file Acceptance 2 wrote:

   ```
   sed -E 's/("timestamp":)[^,}]*/\1"yesterday"/' o/perf/aa-a.json > o/perf/bad.json
   bin/cosmic --make run _perf/gate.tl compare o/perf/bad.json o/perf/aa-b.json o/perf/selfb.json 2>&1 | head -2
   ```

   prints
   `o/perf/bad.json: not a perf results file (meta.timestamp: expected number, got string)`
   and then `perf-compare: FAIL`, exiting non-zero. It must NOT print a
   Lua traceback or `bad argument #1 to 'floor'`. The load failure is
   reached before the identity rule (`identity_refusal` returns nil for
   a file that will not load, `_perf/gate.tl:112-118`), so the
   same-binary refusal of Acceptance 3 does not mask this case. Both
   the wrapper's wording and the `sed` rewrite were verified live
   (Evidence 5). On a tree where `RESULTS_SPEC` does not name
   `timestamp`, the same command reaches the `math.floor` throw
   instead — that is the regression this case pins.

5. **The unit tests.** `bin/cosmic --make test _perf/compare_test.tl`
   ends `test: PASS`, and

   ```
   git diff origin/main...HEAD -- _perf/compare_test.tl | grep -c '^+local function test_'
   ```

   is `5` — the five named in `## Change`, no fewer and no more. (There
   are 25 on `origin/main` today:
   `git show origin/main:_perf/compare_test.tl | grep -c '^local function test_'` → `25`.)

6. **No bar, threshold, or classifier moved.**

   ```
   git diff origin/main...HEAD -- _perf/compare.tl | grep -E 'DEFAULT_THRESHOLD_PCT|TRIAGE_K'
   git grep -n 'noise_floor\|threshold_pct *=' -- _perf/bench
   ```

   Both empty (the second is empty on `origin/main` today). And
   `git diff origin/main...HEAD -- _perf/compare.tl` shows changes only
   in the requires, in `RESULTS_SPEC` and its docstring, in the two new
   file-local functions, and in `format`'s docstring and body — no
   added or removed line inside `diff`, `triage`, `triage_many`,
   `loudest_control`, `identity_refusal`, `format_delta` or
   `format_identity`.

7. **The diff is exactly three files.**

   ```
   git diff origin/main...HEAD --name-only
   ```

   prints exactly `_perf/compare.tl`, `_perf/compare_test.tl`,
   `_perf/perf_types.tl` and nothing else — four, adding
   `_perf/report.tl`, only under the line-cap fallback in `## Change`.
   `_perf/run.tl` and `_perf/gate.tl` must NOT appear. Use the
   THREE-dot form throughout: the two-dot form prints main's forward
   progress on a stale checkout and has produced false clean readings
   here before.

8. **Nothing outgrew the file cap.**

   ```
   wc -l _perf/compare.tl _perf/compare_test.tl _perf/perf_types.tl
   ```

   each ≤ 500. (On `origin/main` they are 399, 360 and 100; the
   projection after this change is ~464, ~445 and ~105, or ~481 for
   `compare.tl` if #1486 lands first — Evidence 10.) Also
   `wc -l _perf/gate.tl` is unchanged at 478, since this diff does not
   touch it.

## Enablement

**None needed. The blocker cleared:** 3IUBNQZZ landed as #1485
(`origin/main` `71e7d312`; Evidence 8), so `format_identity`, the
widened `format(deltas, base?, cur?)`, and `gate.tl`'s `print_report`
are all in the tree. This item's diff changes no exported signature and
no cross-`_perf` call, so it clears the `_perf/skew_test.tl` wall
(3IVF3HbV) by construction — and Evidence 11 clears it by measurement,
having type-checked the exact `## Change` code under the pinned
bootstrap before this spec asserted it.

**No new blocker.** #1486 (3IVLAF3Z) is open over `_perf/compare.tl`
and `_perf/gate.tl` but touches disjoint regions and adds nothing this
item reads (Evidence 13); neither ordering constrains the other.

The wrong turns a literal-minded session could take are closed above
rather than left to judgment:

- *"`shape.into` drops the field, so reading it needs the spec entry"* —
  the opening capture (and this item's title) says exactly this and it
  is false; Evidence 4 measures it, and the Change states the real
  reason the entry is added (validation, Evidence 5).
- *"use `shape.integer`, the stamp is whole seconds"* — it is, but
  `integer` REFUSES a fractional value and would turn a loadable file
  into a refused one. The Change says `shape.number` and why; Evidence
  5 probes C and D show both outcomes.
- *"`print(time.format_iso8601(t))`"* — it returns two values and
  spreads; the Change assigns it to a single-valued local. Evidence 12
  records the exact error message this produces.
- *"guard `base.meta.timestamp` in place"* — record fields do not
  narrow in Teal. The Change copies each to a local and guards the
  local, and the whole function is quoted so there is nothing to
  reconstruct.
- *"add the new functions to the `compare` record"* — Non-goals forbid
  it; they are file-local.
- *"put it in `gate.tl` next to `print_report`"* — `gate.tl` has 22
  lines of headroom and is a Non-goal. The line is produced in
  `compare.format`.
