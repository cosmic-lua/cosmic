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

## Enablement

None needed. Everything the Change touches is measured above at
`54aa87df`: the five print sites and their two sides, the row width
that rules out a column, the 12-hex prefix `identity_refusal` already
uses, and the absence of any committed per-scenario threshold. The
evidence base is 3IU0GxoA's Result — read its byte-identical
cross-session control table and its "What this does NOT license"
paragraph before implementing; 3ISlWFiS and 3ITOUv0w carry the per-arm
readings and hashes that control rests on.
