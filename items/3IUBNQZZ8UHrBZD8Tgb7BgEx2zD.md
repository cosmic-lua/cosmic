## Goal

G6 — the defining paths, ratcheted: a compare row can be traced to the
binary that produced it.

Narrowed 2026-08-27 (third rework). The two-part Change this item
carried is now ONE part: the founded traceability gap. Part 2 — a
per-scenario floor derived from cross-window A/A history — is DROPPED
here and re-filed as its own capture (3IVDirCO), for the reason the
bounce established and this refine confirms in the tree: **the history
it would read does not exist.** `_perf/gate.tl`'s `selfcheck` takes
`A.json B.json`, measures into both, compares, and returns; nothing
accumulates, and `o/perf/*.json` is never committed (AGENTS.md). So
"derive a floor from accumulated A/A spreads" is not an implementation
detail, it is a decision to build a history store — a different item,
with its own evidence and its own record. Keeping the two together is
what made this spec unimplementable twice.

The title still names the dropped half; no verb renames an item
(3IFWAdlL, band 1, backlog). Read the title as the opening hypothesis,
not as this item's scope. **The scope is the `## Change` below.**

What remains is founded, and 3IU0GxoA's Result is what founds it:

- **The gate records nothing about which binary produced a row.**
  `_perf/run.tl:143` writes `meta.bin_sha` (a `hash.sha256_hex` of the
  running binary) into every results file, and `_perf/compare.tl` reads
  it in exactly one place — `identity_refusal`, which either refuses
  the pair or stays silent. No printed row, and no printed report,
  says which binary either side came from.
- **That silence is load-bearing, not cosmetic.** Between measurement
  sessions the absolute level of `codec_base64_roundtrip_64k` moves
  20-33% with the binary BYTE-IDENTICAL (3ISlWFiS and 3ITOUv0w each
  measured cosmic `d8492168eace…`, `sha256sum`-verified in both and a
  third time by 3ITHROpY: median 191.31 µs in one session, 144.29 µs
  in the other, raw ranges disjoint). A reader holding two reports
  cannot tell from the reports whether the levels differ because the
  code differs or because the session does.
- **Within one session the scenario is stable** — 40 isolated launches
  over 40 minutes on one recorded binary held median 190.0 µs at CV
  2.1%, unimodal, no trend between halves. So the reading a header
  makes possible ("these two rows came from the same binary in the
  same run") is the reading that actually separates signal from
  session.

## Evidence (measured 2026-08-27, this repo at `54aa87df`)

**The gap reproduces verbatim.** The bounce recorded it 40 minutes
before this refine, on binary `145057b9fe90…` at main `267c2a4d`; the
two commits since (#1458, #1459) delete test self-call lines only and
touch no `_perf` source, so it stands. A/A selfcheck, same binary,
same window:

```
o/bin/cosmic --make run _perf/gate.tl selfcheck <scratch>/aa-a.json <scratch>/aa-b.json --only codec_base64_roundtrip_64k
```

```
codec_base64_roundtrip_64k      201.49 µs ->    214.04 µs     +6.2%  (noise  ±52.4%)  ok
perf-selfcheck: nothing exceeded the bar — the machine is quiet at this threshold
```

Name, base, current, delta, noise, verdict — six fields, no binary
identity on either side.

**The print sites are five, all in two files**, and every one of them
already has both sides in reach:

```
git grep -n 'compare\.format(' -- _perf | grep -v compare_test
```

→ `_perf/gate.tl:143` (`opts.baseline` vs `opts.current`),
`_perf/gate.tl:199` and `:250` (`base_side` vs `retry`),
`_perf/gate.tl:290` (selfcheck, `opts.a` vs `opts.b`), and
`_perf/run.tl:358` (`base` and `cur`, already loaded as `pt.Results`
locals two dozen lines above).

**A per-row column will not fit.** `format_delta`
(`_perf/compare.tl:237-250`) emits `%-28s %12s -> %12s  %8s  (noise
%7s)  %s`, which is 85 columns before the verdict word. A 12-hex
column on each side adds 26 more. The 90-column house style is not a
gate, but a 111-column table is not a table anyone reads.

**There is no committed per-scenario threshold to grow.** The only
committed number is `DEFAULT_THRESHOLD_PCT = 10.0`
(`_perf/compare.tl:19`), and no scenario module carries a
`noise_floor_pct`:

```
git grep -rn 'noise_floor\|threshold_pct *=' -- _perf/bench
```

→ no matches. So the "no threshold ends larger than it starts" bound
is checked by showing that line and that grep unchanged.

## Change

**The binary identity is a property of a results FILE, not of a row.**
Every row in one report comes from the same pair of files, so the
identity is printed ONCE, as a header line above the rows — not as a
per-row column, which the width measurement above rules out.

1. **`_perf/compare.tl`** — add

   ```teal
   local function format_identity(base: pt.Results, cur: pt.Results): string
   ```

   returning one line, using the same 12-hex prefix
   `identity_refusal` already uses (`string.sub(sha, 1, 12)`,
   `_perf/compare.tl:319`) so the two agree on sight:

   ```
   binaries: base 145057b9fe90  current 145057b9fe90  (same)
   binaries: base 145057b9fe90  current 9f2c1ab30de4  (differ)
   binaries: base 145057b9fe90  current unknown  (unverifiable)
   ```

   `unknown` is the word for a side whose `meta.bin_sha` is absent, and
   `(unverifiable)` the verdict when either side is unknown — never
   `(same)`, which would assert what the file does not say. Export it
   beside `format_delta`.

2. **`_perf/compare.tl`** — widen `format` to

   ```teal
   local function format(deltas: {pt.Delta}, base?: pt.Results, cur?: pt.Results): string
   ```

   prepending `format_identity(base, cur)` when BOTH are non-nil, and
   emitting exactly today's text when either is nil. Optional
   parameters, so no existing caller or test has to change to keep
   working. Update the exported record type to match.

3. **`_perf/gate.tl`** — add a file-local

   ```teal
   local function print_report(base_path: string, cur_path: string, deltas: {pt.Delta})
   ```

   which loads both paths with `compare.load_results` and prints
   `compare.format(deltas, base, cur)` (a `| nil` from a failed load
   flows into the optional parameter and drops the header — a file
   that will not load is the next call's error to report, in its own
   words, exactly as the existing local `identity_refusal` already
   reasons at `_perf/gate.tl:107-110`). Replace all four
   `print(compare.format(deltas))` with `print_report(...)` over the
   pair each site just compared, named in Evidence.

4. **`_perf/run.tl:358`** — `print(compare.format(deltas, base, cur))`.
   Both locals are already in scope and already narrowed.

5. **`_perf/compare_test.tl`** — four cases: the header's three states
   (`same`, `differ`, `unverifiable` with one side absent), and that
   `format(deltas)` with no identity arguments is byte-identical to
   what it returns today.

## Non-goals

- **No threshold, bar, or noise floor changes anywhere**, and in
  particular none for `codec_base64_roundtrip_64k`, on 3IU0GxoA's
  evidence. That evidence makes the scenario look MORE stable within a
  session, not less: its 40-run bracket (CV 2.1%) is tighter than the
  ±4.8% figure 3ISlY5Xl's arithmetic used. 3ISlY5Xl held a release at
  +21.0% via `21.0 > max(10.0, 2 x 4.8)`, and the release lane measures
  baseline and candidate in the SAME job on the SAME runner — the
  interleaved shape the cross-session effect cannot reach. The 20-33%
  cross-session spread is not a noise budget for that gate.
- **No history store, and no derived per-scenario floor.** That is
  3IVDirCO, and it needs a decision this item is not the place for.
- No change to `identity_refusal`'s rule, its wording, or where the
  gate calls it. This item makes the identity VISIBLE; what the gate
  REFUSES on is untouched.
- No verdict, triage, or `diff` change — no row's classification moves.
- No scenario or `check()` changes; no weakening or removal of codec
  rows from any compare.
- The interleaved A/B within one session
  (`skills/optimize/measurement.md`) stays the instrument of record for
  codec claims; a header does not replace it.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.

- **A compare report names a binary for both sides.** Build, then:

  ```
  o/bin/cosmic --make run _perf/gate.tl selfcheck o/perf/aa-a.json o/perf/aa-b.json --only codec_base64_roundtrip_64k
  ```

  Its first line matches `^binaries: base [0-9a-f]{12}  current [0-9a-f]{12}  %(same%)$`
  — a selfcheck pair is same-binary by construction, so `(same)` is the
  verdict it must print — and the `codec_base64_roundtrip_64k` row
  follows unchanged in its six fields. Today the same command prints no
  such line at all (Evidence).

- **The compare gate names them too**, over a genuine two-file compare:

  ```
  o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k --out o/perf/a.json
  o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k --out o/perf/b.json
  o/bin/cosmic --make run _perf/gate.tl compare o/perf/a.json o/perf/b.json o/perf/aa-b.json
  ```

  prints a `binaries:` line above the rows of every table it prints,
  and still ends `perf-compare: PASS` or `perf-compare: FAIL` as it
  does today.

- **No threshold ends larger than it starts.**
  `git diff origin/main -- _perf/compare.tl | grep DEFAULT_THRESHOLD_PCT`
  is empty, and
  `git grep -rn 'noise_floor\|threshold_pct *=' -- _perf/bench`
  is empty (it is empty on `origin/main` today — Evidence).

- **No row's classification moves.**
  `bin/cosmic --make test _perf` ends `test: PASS`, and the diff
  touches no line of `diff`, `triage`, `triage_many`, `loudest_control`
  or `identity_refusal`:
  `git diff origin/main -- _perf/compare.tl` shows changes only inside
  `format_delta`'s neighbours — the new `format_identity`, `format`'s
  signature and first lines, and the exported record type.

- The diff is confined to `_perf/compare.tl`, `_perf/gate.tl`,
  `_perf/run.tl`, `_perf/compare_test.tl`:
  `git diff origin/main --name-only` names those four and nothing else.

- **The file cap holds.** `wc -l _perf/gate.tl _perf/compare.tl` reports
  each under the 500-line ceiling `cosmic --check lint` enforces (and
  `--make ci` runs). Re-measured at `origin/main` = `3ff022d3`:
  `git show origin/main:_perf/gate.tl | wc -l` is 460 and
  `git show origin/main:_perf/compare.tl | wc -l` is 357, so the
  Change's one new `gate.tl` local lands inside 40 lines of headroom.
  If a concurrent landing has eaten that headroom by pull time, bounce —
  splitting `gate.tl` is not in this slice.

- **The new tests are runner-mode: defined, never called.**
  `grep -c '^local function test_' _perf/compare_test.tl` is 25 — it is
  21 on `origin/main` today
  (`git show origin/main:_perf/compare_test.tl | grep -c '^local function test_'`
  → `21`) and the Change adds exactly the four it names — and
  `grep -c '^test_' _perf/compare_test.tl` prints `0` (grep exits 1 on
  no match; printing `0` is the passing outcome). `origin/main`'s
  `_perf/compare_test.tl` already carries zero call-after-define lines,
  so adding one would be a regression against the tree's convention,
  not compliance with AGENTS.md's older wording.

## Enablement

None needed. Everything the Change touches is measured above at
`54aa87df`: the five print sites and their two sides, the row width
that rules out a column, the 12-hex prefix `identity_refusal` already
uses, and the absence of any committed per-scenario threshold. The
evidence base is 3IU0GxoA's Result — read its byte-identical
cross-session control table and its "What this does NOT license"
paragraph before implementing; 3ISlWFiS and 3ITOUv0w carry the per-arm
readings and hashes that control rests on.

**Superseded 2026-08-28 — see `## Refine — 2026-08-28` at the end of
this spec.** "None needed" was false; the bounce immediately below
records why, and that refine settles it: the blocker `3IVF3HbV` has
merged (`3ff022d3`), so this slice takes route 2 and lands unchanged in
ONE PR. The enablement record for this item is that section, not this
paragraph. Everything else this paragraph says — the evidence base to
read before implementing — still stands.

## Bounce — 2026-08-27, returned to plan (session e532d9f6)

Built and returned unopened. The five numbered edits of `## Change`
are implemented, correct and behaviourally verified on branch
`claude/3IUBNQZZ-binary-identity` (commit `2ad10a26`, pushed, no PR).
Every acceptance criterion passes EXCEPT `ci: PASS`, and it fails for
a structural reason this spec does not settle and its own four-file
diff wall forbids fixing.

**`## Enablement` above says "None needed". That is false**, and this
is the correction: `_perf/skew_test.tl` type-checks every non-test
`_perf/**` file under the PINNED bootstrap, and the binary's embedded
`.tl/_perf/*.tl` shadows the tree — so the guard checks the tree's
`gate.tl` and `run.tl` against the pinned release's `compare.tl`.
Widening `compare.format` therefore fails on the very PR that
introduces it:

```
_perf/gate.tl:128:23: error: wrong number of arguments (given 3, expects 1)
_perf/run.tl:358:23: error: wrong number of arguments (given 3, expects 1)
```

`bin/cosmic --make ci` ends `ci: FAIL (coverage)` with
`_perf/skew_test.tl` the SOLE failure out of 933 tests; fmt, check,
example and lint are clean. Causation proven both ways: `git stash`
then `bin/cosmic --make test _perf/skew_test.tl` ends `test: PASS`,
unstashed it fails. `_perf/compare.tl` has not been touched since the
guard landed (`ccd246ab`, #1427), so this is the FIRST `_perf`
exported-signature change after the guard and no precedent exists.

The defect is general — any `_perf` signature change a sibling `_perf`
module calls is unlandable in one PR — and is captured as
**3IVF3HbV**, with the decision it needs.

**Everything else measured clean**, so the next pull starts from here:

- `bin/cosmic --make test _perf/compare_test.tl` → `test: PASS (1 file)`,
  25 tests (the 21 that existed plus the 4 this Change specifies).
- `o/bin/cosmic --make run _perf/gate.tl selfcheck …` prints
  `binaries: base 561f2b76e463  current 561f2b76e463  (same)` — the
  Acceptance regex, matched — with the six-field row unchanged below it.
- `git diff origin/main -- _perf/compare.tl | grep DEFAULT_THRESHOLD_PCT`
  empty; `git grep -rn 'noise_floor\|threshold_pct *=' -- _perf/bench`
  empty; `git diff origin/main --name-only` names exactly the four
  files and nothing else.
- **No Evidence drift.** Both Evidence commands reproduce exactly at
  `54aa87df`; the five print sites are at the precise lines named
  (`gate.tl:143,199,250,290`, `run.tl:358`).

**What the next refine must settle: one line of Enablement**, naming
which route this slice takes — and nothing else in this spec changes.

1. **Stage behind a release and a pin bump**, CLAUDE.md's cold-build
   rule in another guise: land `compare.tl` alone, cut a release
   carrying it, bump `bin/cosmic.pin`, then land the callers. Two PRs
   and a release; this spec authorizes neither.
2. **Fix the skew guard first** (3IVF3HbV) so sibling `_perf` modules
   resolve from the tree ahead of the embed, then land this unchanged
   as one PR. This is the route that removes the cost for every future
   `_perf` change, not just this one, and it makes 3IVF3HbV a blocker
   of this item rather than a sibling of it.

Route 2 is the one to weigh first: route 1 pays the two-PR cost once
per `_perf` signature change forever, and the guard not matching its
own docstring is a defect either way.

## Refine — 2026-08-28: route settled, evidence re-measured at `3ff022d3`

Pulled from `plan`, unclaimed, blocker cleared. This pass changes NO
scope: `## Change` and `## Non-goals` are untouched, the wall on
thresholds stands (see "The two walls" below), and the only additions
are two Acceptance bullets, one pointer in `## Enablement`, and this
record. All measurements below were taken on 2026-08-28 against
`origin/main` = `3ff022d3` and are runnable from the repo root.

**Enablement, settled: route 2. The blocker merged.** `3IVF3HbV`
landed as `3ff022d3` ("perf gate: measure the baseline against the
tree's `_perf`, not the pin's", #1480). Its commit message names this
item's exact failure as one of the two things it fixes: *"That also
made every `_perf` signature change unlandable in one PR — the skew
guard type-checked the tree's `_perf` against the pin's `_perf`
declarations too."* The guard now builds a `_perf`-only include
directory and hands it to the bootstrap checker:

```
git show origin/main:_perf/skew_test.tl | grep -n 'include-dir\|perf_only_include_dir'
```

→ `63:local function perf_only_include_dir(): string`,
`89:    "--include-dir", perf_only_include_dir()}`. Its own docstring
states the property this item needs, in its own words
(`git show origin/main:_perf/skew_test.tl | sed -n '22,28p'`):
*"Caller include dirs come first, so a `_perf`-only directory resolves
`_perf.*` declarations from the tree — which is what lets a `_perf`
signature change land in one PR — while `cosmic.*` still comes from
`/zip/.tl`, the pin's."*

That is the route-2 condition the bounce asked the next refine to
settle, and it is settled by the blocker's own merge rather than by
this spec. The mechanism was already measured end-to-end against a
tree carrying THIS item's widened signature, before `3IVF3HbV` merged:
the block edge's own reason records a run at `8269ff42` with
`compare.format` widened to `(deltas, _base?, _cur?)` and all five call
sites passing three arguments — bare gives five `wrong number of
arguments (given 3, expects 1)` at exit 1, `--include-dir <a dir
holding only _perf>` gives exit 0 over 30 files with zero errors, and
an invented `cosmic.literal` API used from a `_perf` file still fails
under that same scope (so the guard did not go blind). Nothing has
touched `_perf/compare.tl` since:
`git log --oneline origin/main -1 -- _perf/compare.tl` is `ef963bab`
(#1419), which predates the guard.

So: **no blocker items remain, `blocked_by` is empty, and this slice
lands unchanged in one PR.** The implementer runs
`bin/cosmic --make test _perf/skew_test.tl` before opening the PR — it
is the one test the previous attempt failed, and it is expected to end
`test: PASS` now.

**Evidence drift: the four gate print sites moved, nothing else did.**
Two commits touched `_perf/gate.tl` since `54aa87df` — `b0aeb1dd`
(`3IVL9t0P`) and `3ff022d3` (`3IVF3HbV`) — and the file grew 406 → 460
lines. The five print sites are still five, still in two files, and
still have both sides in reach; only the `gate.tl` line numbers
changed:

```
git grep -n 'compare\.format(' origin/main -- _perf | grep -v compare_test
```

→ `_perf/gate.tl:153` (`opts.baseline` vs `opts.current`),
`_perf/gate.tl:235` and `:286` (`base_side` vs `retry`),
`_perf/gate.tl:326` (selfcheck, `opts.a` vs `opts.b`), and
`_perf/run.tl:358` (`base` and `cur`, both already narrowed
`pt.Results` locals at `_perf/run.tl:321-330`). **Read
`## Change` step 3's site list as 153/235/286/326, not
143/199/250/290.** The pairs named there are unchanged and correct.

Everything the rest of `## Evidence` asserts reproduces byte-for-byte
at `3ff022d3`:

- `_perf/compare.tl` is unchanged at 357 lines, so
  `DEFAULT_THRESHOLD_PCT = 10.0` is still `_perf/compare.tl:19`,
  `format_delta` still `:237-250`, `format` still `:255`, and the
  12-hex prefix `string.sub(sha, 1, 12)` still inside
  `identity_refusal` at `:318-326`.
- `git grep -rn 'noise_floor\|threshold_pct *=' -- _perf/bench` → still
  no matches. No scenario carries a per-scenario floor.
- `_perf/run.tl` is unchanged at 405 lines; the print site is still
  `:358`.

One correction to `## Evidence`, measured rather than carried over: the
row prefix before the verdict word is **86 bytes / 84 display columns**,
not 85 —

```
printf '%-28s %12s -> %12s  %8s  (noise %7s)  ' codec_base64_roundtrip_64k '201.49 µs' '214.04 µs' '+6.2%' '±52.4%' | wc -c
```

→ `86` (the two `µ` are two bytes each, and Lua's `%12s` pads by bytes).
The conclusion is unchanged and is what the Change rests on: two 12-hex
columns plus their labels push the row past 110 columns, so the
identity goes in a header line, not in the row.

**What `3IVL9t0P` (`b0aeb1dd`) changes here: nothing in scope, and one
thing worth knowing.** It re-keys the strike-twice rule to a re-measured
baseline, so at `gate.tl:235` and `:286` the base side may now be
`retry_path(opts.baseline)` rather than the caller's baseline file —
but only when `--baseline-bin` was passed, which is the only way
`measure_baseline` is set (`_perf/gate.tl:386-423`). Both are paths,
both load through `compare.load_results`, and `gate_inner` already
refuses the pair unless the two baseline files name the SAME binary
(`identity_refusal(opts.baseline, base_side, true)`). So the header
prints `(same)` there by construction and the Change needs no
adjustment; the header simply also makes visible WHICH baseline file
the printed rows were judged against, which is the reading `3IVL9t0P`
made load-bearing. Its re-key block recomputes deltas
(`compare_once(base_side, opts.current, opts.threshold)`) but does NOT
print them, so it is not a sixth print site — the site list stays at
five.

**What `3IWx3I4Z` is, and why it earns a scope note rather than an
edge.** `3IWx3I4Z` ("the baseline pair is an unread A/A control") is
`backlog`, under the same parent, and lives in the same file — but in
the functions this item is already fenced OUT of: it needs
`triage_many` to take a second control group and asks whether
`loudest_control` becomes exported. This item's `## Non-goals` already
says "No verdict, triage, or `diff` change — no row's classification
moves", and its `## Acceptance` already requires that the diff touch no
line of `diff`, `triage`, `triage_many`, `loudest_control` or
`identity_refusal`. The two are function-disjoint inside one file, so
**no `block` edge in either direction**, and no duplicate work: this
item makes an identity VISIBLE, `3IWx3I4Z` changes what the gate
CREDITS as noise. The only interaction is scheduling — if `3IWx3I4Z`
is ever pulled while this is in flight, the two branches touch one
file and should be serialized by whoever pulls second, not by a board
edge.

**Two more `_perf` siblings, for the implementer's awareness, also
without edges.** `3IVLAF3Z` (`plan`) changes what
`identity_refusal` does with a STAMPLESS file; this item's
`(unverifiable)` header state is display-only and stays correct under
either landing order, and `## Non-goals` already forbids touching
`identity_refusal`'s rule. `3IVEEDO8` (`plan`) is blocked BY this item
and extends the very header line this Change introduces with the
measurement window, so `format_identity` should read as a line that can
grow a second fact — which the specified signature already allows.

**`unknown` is a printed word, never a stored one.** `_perf/run.tl`
deliberately leaves `meta.bin_sha` ABSENT when the binary cannot be
hashed, and says why in a comment directly above the write
(`git show origin/main:_perf/run.tl | sed -n '138,140p'`): *"no
`bin_sha` at all — rather than filled in with a word like `unknown`,
which reads as an answer and compares equal to the next run that could
not name its subject either."* `## Change` step 1's `unknown` is the
word `format_identity` PRINTS for an absent stamp. It must not be
written into `meta`, and the Change touches no write site.

**The two walls, confirmed standing.** Neither is weakened by this
pass, and both must survive any future one:

1. `## Non-goals`' first bullet — no threshold, bar, or noise floor
   changes anywhere, and none for `codec_base64_roundtrip_64k` in
   particular — is untouched, including its arithmetic: `3ISlY5Xl` held
   a release at +21.0% via `21.0 > max(10.0, 2 x 4.8)`, and the
   20-33% cross-session level spread `3IU0GxoA` measured on a
   byte-identical binary is NOT a noise budget for a gate whose two
   sides are measured interleaved in one job. Widening that floor would
   retire the arithmetic; this item does not touch it.
2. `## Acceptance`' "No threshold ends larger than it starts" bullet —
   `git diff origin/main -- _perf/compare.tl | grep DEFAULT_THRESHOLD_PCT`
   empty and `git grep -rn 'noise_floor\|threshold_pct *=' -- _perf/bench`
   empty — is untouched and re-verified above as empty on `origin/main`
   today.

The `## Enablement` pointer to `3IU0GxoA`'s "What this does NOT
license" paragraph is likewise untouched: read it before implementing.

**Not measured here, and left to the implementer, deliberately.** No
perf harness was run during this refine. `3IU0GxoA` established that
this container's absolute readings are not comparable across sessions,
and a refine cannot take a reading the implementer will not re-take
anyway. So `## Acceptance`'s two harness commands — the `selfcheck`
whose first line must match
`^binaries: base [0-9a-f]{12}  current [0-9a-f]{12}  %(same%)$`, and
the three-file `compare` — are the implementer's work, run in ONE
sitting on a built `o/bin/cosmic`, writing only under `o/` and
committing nothing from `o/perf/`. Neither is a timing judgment: both
assert the presence and shape of a header line, which is exactly the
kind of claim a noisy container CAN settle.

**Title.** Still names the dropped half (a per-scenario floor derived
from cross-window A/A history), which is `3IVDirCO`, not this item; no
verb renames an item (`3IFWAdlL`). The scope is `## Change`.
