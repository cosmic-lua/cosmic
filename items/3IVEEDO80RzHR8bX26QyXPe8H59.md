## Goal

G6 — the defining paths, ratcheted: a compare report can be traced to
the WINDOW it was measured in, not only to the binary it measured.

Three review rounds on 3IU0GxoA were spent establishing, by hand, that
readings quoted side by side came from different measurement windows.
The report the reader holds says nothing about when either side was
measured, and the fact needed to say it is already written into every
results file.

## Evidence (measured 2026-08-27, `origin/main` at `6cd0f8a9`)

Every command below is quoted with its output and is runnable from the
repo root. Where a probe is quoted it was run against `o/bin/cosmic`
`145057b9fe905bb866fa3c03818265e4284a3bcd8367b76d9d5254f3c32a0900`
(built from `267c2a4d`; `git diff --stat 267c2a4d origin/main -- cosmic/shape.tl _perf/`
shows the only `_perf` changes since are test self-call deletions, and
no change at all to `cosmic/shape.tl`, `_perf/compare.tl` or
`_perf/run.tl`).

**1. The stamp is written, once, and it dates the END of the run.**

```
git show origin/main:_perf/run.tl | grep -n 'timestamp'
```
→ `124:    timestamp = time.now(),` — the only match.

`time.now()` is declared `function(): integer, integer`
(`cosmic/time.tl:33`), and a table-constructor field takes the first
value, so `meta.timestamp` is whole seconds. `collect_meta` is called
at `_perf/run.tl:291`, inside the payload constructor, AFTER the
scenario loop at `_perf/run.tl:247-281`. So the stamp is the moment
the results were WRITTEN, not the moment measurement began. The header
this item adds is labelled to match, and `perf_types` is corrected to
say so.

**2. The type already declares it, undocumented.**

```
git show origin/main:_perf/perf_types.tl | grep -n 'timestamp'
```
→ `49:    timestamp: number` — a bare field on `record Meta`, with no
doc comment, while the field beneath it (`bin_sha`, `:51-55`) carries
five lines of one.

**3. Nothing in the comparison half reads it, prints it, or checks it.**

```
git show origin/main:_perf/compare.tl | grep -n 'timestamp'
```
→ no matches (exit 1).

**4. CORRECTION to this item's opening capture: `shape.into` does NOT
drop the field.** The capture asserted that `RESULTS_SPEC`'s silence
makes `shape.into` DROP `timestamp` "before any comparison code could
read it". Measured, that is false, and the spec is written on the
corrected fact. **The item TITLE still carries the wrong word** — no
verb renames an item (3IFWAdlL, band 1, backlog) — so read the title as
the opening hypothesis and this section as the fact.

```
git show origin/main:cosmic/shape.tl | sed -n '30,39p'
```
→ the frozen semantics: "extra keys a Spec does not name are IGNORED"
and "`into` returns the SAME table it was given, not a copy —
`integer` normalizes a whole-valued float to an integer in place,
which is the only write it makes."

Probe (written to a scratch path outside the repo, run as
`o/bin/cosmic <probe>.tl`), using `RESULTS_SPEC`'s exact `meta` shape:

```teal
local json = require("cosmic.json")
local shape = require("cosmic.shape")
local SPEC = shape.record({
    meta = shape.optional(shape.record({bin_sha = shape.optional(shape.string)})),
    results = shape.list(shape.record({name = shape.string})),
  })
local raw = [[{"meta":{"bin_sha":"abc","timestamp":1756305221,"bin":"o/bin/cosmic"},"results":[{"name":"x"}]}]]
local out = shape.into(json.decode(raw), SPEC)
local m = (out as {string: any}).meta -- cast: probe
print("timestamp after into:", tostring((m as {string: any}).timestamp))
```
→ `timestamp after into:	1756305221`

So the value survives `load_results` today, and because `pt.Meta`
declares the field (fact 2), `base.meta.timestamp` type-checks with
`RESULTS_SPEC` untouched. **Naming it in `RESULTS_SPEC` is therefore
not what makes it readable — it is what makes it VALIDATED**, and
fact 5 is why that matters.

**5. Unvalidated, a malformed file throws out of library code.**
`format_iso8601` is declared `function(timestamp: integer): string | nil, string`
(`cosmic/time.tl:306`), so a `number` field must be floored at the
call site. `math.floor` on a non-number throws:

```teal
local v: any = "yesterday"
print(pcall(function() return math.floor(v as number) end)) -- cast: probe
```
→ `false	...: bad argument #1 to 'floor' (number expected, got string)`

A results file carrying `"timestamp":"yesterday"` would reach that
throw from inside `compare.format` — a throw from library code, which
AGENTS.md forbids. Named in `RESULTS_SPEC`, the same file is refused
by `load_results` instead, on the error channel this module already
has. Probe, with `timestamp = shape.optional(shape.number)` added to
the `meta` record of `RESULTS_SPEC`'s exact shape and the same payload
carrying `"timestamp":"yesterday"`:

```
print(tostring(out), tostring(err))
```
→ `nil	meta.timestamp: expected number, got string`

which `load_results` (`_perf/compare.tl:66`) wraps as
`<path>: not a perf results file (meta.timestamp: expected number, got string)`.

`json.encode` writes the field with no space and as a bare integer
(`{"meta":{"bin":"x","timestamp":1787844231},"results":{}}`, same
probe binary), which is what Acceptance 4's `sed` rewrites.

**6. The module's own docstring already states the rule this follows.**
`_perf/compare.tl:29-37`: "The fields perf.run also writes but nothing
here reads (iterations, samples_ns, cpu_ns, min_ns, max_ns, alloc_kb)
are left unnamed: `into` ignores keys a Spec does not name." A field
this module STARTS reading is therefore a field it names, and that
sentence has to be edited when the set changes.

**7. What is already landed, and is NOT this item's to add.**
`format_delta` (`_perf/compare.tl:237-250`) already prints BOTH
absolute levels — its format string is
`"%-28s %12s -> %12s  %8s  (noise %7s)  %s"`, base then current. This
item adds no level column and no per-row field. #1460 (item 3IVDirCO),
which recorded that a within-session regression's magnitude is
level-bound, touched documentation only:

```
git show --stat --format= 6cd0f8a9
```
→ ` skills/optimize/measurement.md | 32 ++++++++++++++++++++++++++++++++`
— one file, nothing under `_perf/`.

**8. The `binaries:` header is NOT landed, and this item composes on it.**

```
git show origin/main:_perf/compare.tl | grep -c format_identity
```
→ `0`. `format_identity`, the widened `format(deltas, base?, cur?)`,
and `gate.tl`'s `print_report` are all 3IUBNQZZ's `## Change`;
3IUBNQZZ is in `plan`, blocked by 3IVF3HbV. Every plumbing edit this
item would otherwise need — carrying both `pt.Results` to the five
`compare.format(` call sites — is that item's, and cutting them in
parallel means two branches rewriting the same header region and both
hitting the same `_perf/skew_test.tl` wall 3IVF3HbV describes. Hence
the blocker in `## Enablement`. After 3IUBNQZZ lands, this item's diff
changes NO exported signature, so it does not meet that wall itself.

**9. The five print sites, for the record** (they are 3IUBNQZZ's to
convert; this item touches none of them):

```
git show origin/main:_perf/gate.tl | grep -n 'compare\.format('
git show origin/main:_perf/run.tl | grep -n 'compare\.format('
```
→ `gate.tl:143,199,250,290` and `run.tl:358`.

**10. Capacity.**

```
git show origin/main:_perf/compare.tl | wc -l      # 357  (143 under the 500 cap)
git show origin/main:_perf/compare_test.tl | wc -l # 290  (210 under the cap)
git show origin/main:_perf/perf_types.tl | wc -l   # 100  (400 under the cap)
```

**11. Width: this cannot ride on the `binaries:` line.** Measured with
`#` on the two literals (probe run under the same binary):

- `binaries: base 145057b9fe90  current 145057b9fe90  (same)` → 57
- `measured: base 2026-08-27T05:50:12Z  current 2026-08-27T14:23:47Z  (current +8h33m)` → 83

Merged into one line they are 130 columns. Two header lines of 57 and
83 each fit the 90-column house style; one line of 130 does not.

## Change

Three files, four edits. The change is: name `timestamp` in
`RESULTS_SPEC` so it is validated, print one second header line beneath
3IUBNQZZ's `binaries:` line, and document what the stamp actually
means.

**1. `_perf/perf_types.tl` — document the field (no type change).**
Above `timestamp: number` (`:49`), add a doc comment saying the stamp
is UNIX epoch seconds, UTC, recorded when the results file is written
— that is, at the END of the run, after every scenario has been
measured. Do not change the declared type: `number` is what a decoded
JSON value is, and narrowing it to `integer` would make
`load_results` reject a file whose stamp round-tripped as a float.

**2. `_perf/compare.tl` — validate the field.** In `RESULTS_SPEC`
(`:38-48`), add to the `meta` record, beside `bin_sha`:

```teal
timestamp = shape.optional(shape.number),
```

`optional`, because a results file written before this field existed,
or by a run that could not stamp itself, must still load — the same
reasoning `bin_sha` already carries. `shape.number`, not
`shape.integer`: `integer` REFUSES a fractional value, and a stamp
that round-tripped through an encoder as `1756305221.0` would turn a
loadable file into a refused one. The whole-seconds guarantee comes
from `time.now()` at the WRITE side (Evidence 1), not from the read
side, and the call site floors anyway. Then
edit the `RESULTS_SPEC` docstring's "fields ... left unnamed"
sentence (`:35-37`) so its list no longer implies `timestamp` is one
of them, and say in one clause why this one is named (it is read by
`format_measured` below, so a non-number would throw downstream).

**3. `_perf/compare.tl` — the header line.** Add
`local time = require("cosmic.time")` to the module's requires
(`:13-17` today — the module does not require it yet), then add two
file-local functions beside `format_identity` and print the second one
from `format`.

```teal
local function format_gap(secs: integer): string
```

renders a signed gap in the largest unit that still answers "same
window or not", deliberately dropping finer precision above a minute:

- `|secs| < 60` → `"+12s"` / `"-12s"`
- `|secs| < 3600` → `"+2m"` / `"-2m"` (floored minutes)
- otherwise → `"+8h33m"` / `"-8h33m"` (`%s%dh%02dm`, floored)

```teal
local function format_measured(base: pt.Results, cur: pt.Results): string
```

returns exactly one line:

```
measured: base 2026-08-27T05:50:12Z  current 2026-08-27T14:23:47Z  (current +8h33m)
```

Rules, all of them:

- Each side renders through `time.format_iso8601(math.floor(ts))`,
  which is UTC with a `Z` suffix and exactly 20 characters
  (`cosmic/time.tl:306`; verified: `format_iso8601(1756305221)` →
  `2025-08-27T14:33:41Z`, unchanged under `TZ=America/Los_Angeles`).
- A side renders as the word `unknown` when its `meta` is absent, its
  `meta.timestamp` is absent, or `format_iso8601` returns nil. `unknown`
  is the same word `format_identity` uses for an unnamed binary, for the
  same reason.
- The parenthetical is `(current <gap>)` where `gap` is
  `format_gap(math.floor(cur_ts) - math.floor(base_ts))`, and
  `(gap unknown)` when EITHER side is `unknown`. It is signed against
  the base, matching the `base -> current` direction `format_delta`
  already reads in.
- `meta` and `timestamp` are record FIELDS, which Teal does not narrow
  (AGENTS.md): copy each to a local and guard the local.
- File-local, not exported. It is reached only through `format`, and
  the tests below drive it that way, so the exported `compare` record
  type does not widen — which is what keeps this diff clear of the
  `_perf/skew_test.tl` wall.

In `format` (`:255-276`, as 3IUBNQZZ leaves it), emit
`format_measured(base, cur)` immediately after the `format_identity`
line, under the same `base ~= nil and cur ~= nil` guard, so that
`format(deltas)` with no identity arguments still returns byte-identical
text to today's.

**4. `_perf/compare_test.tl` — exactly five new test functions**, each
a `test_*` called on the line after its `end` (AGENTS.md), each
driving `compare.format(deltas, base, cur)` over hand-built
`pt.Results` values (no measurement). Their names, so the count in
Acceptance 5 is unambiguous:

- `test_format_measured_line` — both stamps present, current later by
  30815 seconds → the report's SECOND line is exactly
  `measured: base 2026-08-27T05:50:12Z  current 2026-08-27T14:23:47Z  (current +8h33m)`.
- `test_format_measured_negative_gap` — current EARLIER than base by
  the same 30815 seconds → the parenthetical is `(current -8h33m)`.
- `test_format_measured_gap_units` — three assertions, one per
  `format_gap` branch, read off the rendered line: a 12-second gap →
  `(current +12s)`, a 150-second gap → `(current +2m)`, a
  30815-second gap → `(current +8h33m)`. (Verified arithmetic:
  `2026-08-27T14:23:47Z` minus `2026-08-27T05:50:12Z` is 30815 s;
  `30815 // 3600 = 8`, `(30815 % 3600) // 60 = 33`.)
- `test_format_measured_unknown_side` — `cur.meta.timestamp` absent →
  the line is
  `measured: base 2026-08-27T05:50:12Z  current unknown  (gap unknown)`.
- `test_format_without_identity_unchanged` — `compare.format(deltas)`
  with no identity arguments returns text containing neither
  `measured: ` nor `binaries: `, byte-identical to what the same call
  returns today.

## Non-goals

- **No new field in the results file.** `meta.timestamp` already
  exists (Evidence 1); nothing in `_perf/run.tl` changes. In
  particular, do NOT add a start-of-run stamp, a session id, a
  hostname, or a run uuid — the wall-clock stamp already on disk is
  the whole subject.
- **`_perf/run.tl` and `_perf/gate.tl` are not touched at all.** The
  diff is the three files named in `## Change`; neither of those is one
  of them.
- **No gap becomes a decision.** The `measured:` line is
  informational and may never refuse, warn, change an exit code,
  raise a bar, or feed `diff`/`triage`/`triage_many`/`loudest_control`.
  `DEFAULT_THRESHOLD_PCT` stays `10.0` and `TRIAGE_K` stays `2.0`
  (`_perf/compare.tl:19,27`). 3IU0GxoA's "What this does NOT license"
  binds: the 20-33% cross-session spread is NOT a noise budget, and the
  release lane measures baseline and candidate in the SAME job on the
  SAME runner.
- **`identity_refusal` is untouched** — its rule, its wording, and
  where `gate.tl` calls it. This item makes a fact VISIBLE; what the
  gate REFUSES on does not move.
- **No per-row column and no second level field.** `format_delta`
  already prints both absolute levels (Evidence 7) and its format
  string is not edited.
- **No `format_identity` rewrite.** The `binaries:` line lands with
  3IUBNQZZ and is consumed here as-is; this item adds a line beneath
  it and changes none of its text.
- **No history store, no derived per-scenario floor** — that is
  3IVDirCO's subject, and it is not opened here.
- No scenario, `check()`, or bench-module change; no codec row weakened
  or removed from any compare.
- Code comments carry no item ids, PR numbers, or dates
  (`skills/docs-style`).

## Acceptance

Run from the repo root, in order. `o/perf/` is build output and is
never committed.

1. **The repo gate.**
   `bin/cosmic --make ci` ends `ci: PASS`.

2. **The header prints, with both stamps and a signed gap.** Build,
   then run a one-scenario A/A:

   ```
   bin/cosmic --make build
   o/bin/cosmic --make run _perf/gate.tl selfcheck o/perf/aa-a.json o/perf/aa-b.json --only codec_base64_roundtrip_64k > o/perf/selfcheck.txt
   grep -Eq '^measured: base [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z  current [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z  \(current \+([0-9]+s|[0-9]+m|[0-9]+h[0-9]{2}m)\)$' o/perf/selfcheck.txt
   grep -A1 '^binaries: ' o/perf/selfcheck.txt | sed -n 2p | grep -q '^measured: '
   ```

   Both greps exit 0 — the second is what pins the `measured:` line
   immediately below the `binaries:` line 3IUBNQZZ prints — and
   `tail -1 o/perf/selfcheck.txt` is still one of the two
   `perf-selfcheck:` verdict lines the gate prints today
   (`_perf/gate.tl:292-296`), unchanged. On `origin/main` today the
   same command produces no `measured:` line at all, so the first grep
   exits 1 (Evidence 3).

3. **The compare gate prints it too**, over a genuine two-file compare:

   ```
   o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k --out o/perf/a.json
   o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k --out o/perf/b.json
   o/bin/cosmic --make run _perf/gate.tl compare o/perf/a.json o/perf/b.json o/perf/aa-b.json
   ```

   Every table it prints carries a `measured:` line beneath its
   `binaries:` line, and the run still ends `perf-compare: PASS` or
   `perf-compare: FAIL` exactly as today.

4. **A malformed stamp is refused at load, not thrown at format.**

   ```
   sed -E 's/("timestamp":)[^,}]*/\1"yesterday"/' o/perf/a.json > o/perf/bad.json
   o/bin/cosmic --make run _perf/gate.tl compare o/perf/bad.json o/perf/b.json o/perf/aa-b.json
   ```

   fails with exactly
   `o/perf/bad.json: not a perf results file (meta.timestamp: expected number, got string)`
   — the wrapper is `load_results` (`_perf/compare.tl:66`) and the
   inner text is `shape.into`'s, both verified in Evidence 5. It must
   NOT print a Lua traceback or `bad argument #1 to 'floor'`.

   On a tree where `RESULTS_SPEC` does not name `timestamp`, the same
   command reaches the `math.floor` throw instead — which is the
   regression this case pins.

5. **The unit tests.**
   `bin/cosmic --make test _perf/compare_test.tl` ends `test: PASS`, and
   ```
   git diff origin/main...HEAD -- _perf/compare_test.tl | grep -c '^+local function test_'
   ```
   is `5` — the five test functions named in `## Change`, no fewer and
   no more.

6. **No bar, threshold, or classifier moved.**

   ```
   git diff origin/main...HEAD -- _perf/compare.tl | grep -E 'DEFAULT_THRESHOLD_PCT|TRIAGE_K'
   ```
   is empty, and
   ```
   git grep -rn 'noise_floor\|threshold_pct *=' -- _perf/bench
   ```
   is empty (it is empty on `origin/main` today). The diff adds and
   removes no line inside `diff`, `triage`, `triage_many`,
   `loudest_control`, `identity_refusal`, `format_delta` or
   `format_identity`:
   ```
   git diff origin/main...HEAD -- _perf/compare.tl
   ```
   shows changes only in `RESULTS_SPEC`, in `format`'s body, and in the
   two new file-local functions.

7. **The diff is exactly three files.**
   ```
   git diff origin/main...HEAD --name-only
   ```
   prints exactly these three lines and nothing else:
   `_perf/compare.tl`, `_perf/compare_test.tl`, `_perf/perf_types.tl`.
   `_perf/run.tl` and `_perf/gate.tl` must NOT appear. Use the
   THREE-dot form throughout: the two-dot form prints main's forward
   progress on a stale checkout and has produced false clean readings
   here before.

8. **Nothing outgrew the file cap.**
   `wc -l _perf/compare.tl _perf/compare_test.tl _perf/perf_types.tl`
   — each ≤ 500. (On `origin/main` today they are 357, 290 and 100;
   3IUBNQZZ adds to the first two before this item does.)

## Enablement

**Blocked by 3IUBNQZZ**, mirrored in `blocked_by`. That item adds
`format_identity`, widens `format` to `format(deltas, base?, cur?)`,
and converts the five `compare.format(` call sites so both
`pt.Results` reach the formatter. Without it this item would have to
land that same plumbing, which is a second branch over the same header
region and the same `_perf/skew_test.tl` wall recorded as 3IVF3HbV
(3IUBNQZZ is itself blocked on it). With it, this item's diff changes
no exported signature and no cross-`_perf` call, so it clears that wall
by construction.

Nothing else needed. The three wrong turns a literal-minded session
could take here are closed in the spec above rather than left to
judgment:

- *"`shape.into` drops the field, so reading it needs the spec entry"* —
  the opening capture said exactly this and it is false; Evidence 4
  measures it, and the Change states the real reason the entry is
  added (validation, Evidence 5).
- *"use `shape.integer`, the stamp is whole seconds"* — it is, but
  `integer` REFUSES a fractional value and would turn a loadable file
  into a refused one. The Change says `shape.number` and why.
- *"narrow `base.meta.timestamp` with a guard"* — record fields do not
  narrow in Teal. The Change says to copy each to a local.
