## Goal

G9 — every release publishes, measured. `release.yml`'s perf gate has
held every daily release since 2026-08-23 (runs `32699814015`,
`32818853162`, `32940138465` all `failure`; `gh` release list's newest
tag is still `2026-08-23-d71d7f1`). Board item `3ISWHyP7`'s A/B proved
one of the two flagged scenarios — `json_decode_large` — is machine
variance and not code. This slice closes the gate hole that let
variance read as a regression, without excusing the OTHER flagged
scenario, `codec_base64_roundtrip_64k`, which the same A/B showed is a
real +7.8%.

## Evidence

**The hole, read at `main` `ec794d44`.** `_perf/gate.tl:117-181`
(`gate_inner`) measures the current binary up to THREE times —
`opts.current` (measured by the caller), `retry` (`retry_path`, line
`131`), and `opts.selfcheck_b` (line `157`) — and then triages using
exactly ONE same-binary pair: `compare_once(opts.baseline, retry,
opts.threshold, retry, opts.selfcheck_b)` at lines `170-171`.
`opts.current` is compared once at line `123` and never used as a
control again.

`_perf/compare.tl:173-191` (`triage`) reclassifies a regression to the
non-failing verdict `noise` only when that ONE pair showed the same
scenario clearing the bar:

```teal
if sd.verdict == "regression" or sd.verdict == "faster" then
  self_by_name[sd.name] = sd
end
...
if d.verdict == "regression" and sd ~= nil and sd.delta_pct ~= nil
and math.abs(d.delta_pct) <= math.max(d.noise_pct, TRIAGE_K * math.abs(sd.delta_pct)) then
```

So a scenario that is quiet in that one pair and noisy an hour later
keeps its `regression` verdict and holds the release. That is exactly
what happened: `3ISWHyP7` measured the same binary against itself in
suite context and saw `json_decode_large` 1.21 ms -> 1.36 ms
**+12.6%** — had the release lane's own self-check pass caught that
swing, `TRIAGE_K = 2.0` (`_perf/compare.tl:27`) would have cleared the
lane's +11.6% flag (`11.6 <= max(10.0, 2 x 12.6 = 25.2)`) and the
release would have published.

**The fix is free measurements, not a wider bar.** Three same-binary
result files already exist by the time `gate_inner` triages, so there
are THREE control pairs available — `current`/`retry`,
`current`/`selfcheck_b`, `retry`/`selfcheck_b` — where the code uses
one. Taking each scenario's LARGEST observed same-binary swing across
all available pairs triples the chance of catching a scenario
misbehaving, at zero extra runtime and with no threshold moved.

**It must not excuse base64, and does not.** `3ISWHyP7`'s six isolated
readings put `codec_base64_roundtrip_64k`'s same-binary spread at
±3.3–4.8% on the settled rounds, against a release-lane regression of
**+21.0%**. `21.0 > max(10.0, 2 x 4.8 = 9.6)`, so the scenario keeps
its `regression` verdict under any of the three pairs and the gate
still refuses the release. That asymmetry is the property this slice
is accountable for, and `Acceptance` pins it with both scenarios'
real numbers as fixtures.

**Capacity, measured now** (`wc -l _perf/compare.tl _perf/compare_test.tl
_perf/gate.tl _perf/gate_test.tl`): 316, 264, 304, 366 — 184, 236,
196 and 134 lines of headroom under the 500-line cap.

**Callers that must keep working** (`grep -rn "compare.triage" --include=*.tl .`
outside `o/`): `_perf/gate.tl:77`, `_perf/run.tl:354`, and seven call
sites in `_perf/compare_test.tl` (lines 181, 193, 207, 222, 230, 244,
256). All nine pass the current four-results signature, which is why
`Change` keeps it.

**The next record number is D31**: `ls docs/decisions/d*.md | wc -l`
→ 30, newest `docs/decisions/d30-throw-exit-boundaries.md`.

## Change

Two files of product code, two test files, one decision record, one
regenerated index.

1. **`docs/decisions/d31-gate-noise-from-every-control-pair.md`** — a
   new record in the form `skills/decide/SKILL.md` fixes and
   `_build/docs_test.tl` gates: H1 exactly
   `# D31 — the perf gate reads noise from every same-binary pair it
   already measured`, then the `- **date:** 2026-08`,
   `- **status:** active`, `- **context:**`, `- **decision:**`,
   `- **rejected:**` and `- **consequences:**` bullets, matching
   `docs/decisions/d29-tests-run-because-defined.md`'s shape.

   `context` states the hole from `## Evidence` above. `decision`
   states: a scenario's noise credit is the LARGEST same-binary swing
   across every control pair the gate has already measured, not the
   swing in one designated pair; `TRIAGE_K` and the 10% default
   threshold are unchanged. `rejected` names the two options that were
   weighed and lost — raising `--threshold` or adding either scenario
   to a noise-excused set (rejected because it would also excuse
   base64's real +21%), and a committed per-scenario noise profile
   (rejected as premature: it is a fourth committed floor under D27
   with a maintenance cost this hole does not justify, and it can
   still be taken later). `consequences` states plainly what was given
   up: this LOWERS the false-red rate by sampling three pairs instead
   of one, it does not eliminate it — a scenario quiet in all three
   pairs and noisy an hour later still reads as a regression, and the
   remedy for that remains a re-run.

2. **`_perf/compare.tl`** — add `triage_many`, and re-express `triage`
   as a wrapper so all nine existing callers are untouched:

   ```teal
   local function triage_many(base: pt.Results, cur: pt.Results,
       controls: {pt.Results}, threshold_pct?: number): {pt.Delta}, integer
   ```

   It computes `diff(controls[i], controls[j], threshold_pct)` for
   every unordered pair `i < j`, and builds `self_by_name` keyed on
   scenario name holding, per scenario, the entry with the largest
   `math.abs(delta_pct)` among pairs where that scenario's verdict was
   `regression` or `faster`. The reclassification test below it is the
   existing one, unchanged, including `TRIAGE_K`. Fewer than two
   controls means no pairs and no reclassification — identical to
   today's behaviour when the A/A is absent.

   `triage(base, cur, na, nb, t)` becomes
   `return triage_many(base, cur, {na, nb}, t)`. Export `triage_many`
   on the module record beside `triage` (the record at
   `_perf/compare.tl:294-303` and the table at `305-315`).

3. **`_perf/gate.tl`** — teach the triage step to pass all three
   same-binary files. At lines `169-171`, replace the
   `compare_once(..., retry, opts.selfcheck_b)` call with a call that
   loads `opts.current`, `retry` and `opts.selfcheck_b` and passes
   them as `controls` to `compare.triage_many`. `opts.current` joins
   the control set ONLY when `identity_refusal(retry, opts.current,
   true)` returns nil; when it does not, drop `opts.current` from the
   controls silently and carry on with the other two — a mismatched
   binary is a bonus control lost, not a new refusal, and today's
   behaviour is what remains. The existing
   `identity_refusal(retry, opts.selfcheck_b, true)` check at line
   `164` stays exactly as it is and still refuses.

   Extend `compare_once`'s optional-control parameters, or add a
   sibling helper beside it — either shape is fine as long as
   `compare_once`'s existing two-control call at line `77` keeps its
   signature and its `_perf/run.tl:354` counterpart is untouched.

4. **`_perf/compare_test.tl`** — add two test functions, each called
   on the line after its `end` per AGENTS.md:

   - `test_the_loudest_control_pair_sets_the_noise_credit` — three
     controls where the scenario is quiet in one pair and swings in
     another; assert the regression reclassifies to `noise` and
     `failures` drops by one. Build it from `3ISWHyP7`'s real
     `json_decode_large` numbers: baseline `798.63` µs, current
     `891.35` µs (+11.6%), controls at `1210`, `1360` and `1215`
     ns-scaled so one pair reads ~+12.6% and another ~+0.4%.
   - `test_a_real_regression_survives_every_control_pair` — the
     `codec_base64_roundtrip_64k` case: baseline `132.05` µs, current
     `159.82` µs (+21.0%), three controls within 4.8% of each other.
     Assert the verdict stays `regression` and `failures` is
     unchanged. This is the test that proves the change did not break
     the gate.

5. **`_perf/gate_test.tl`** — add one test function,
   `test_the_gate_triages_against_every_measured_control`, called on
   the line after its `end`: drive `gate` through its full
   retry-then-selfcheck path with a `measure` stub whose successive
   writes make `current` vs `selfcheck_b` the loud pair and `retry`
   vs `selfcheck_b` the quiet one, and assert the gate exits `0`. It
   fails before change (3) and passes after.

6. **Regenerate the decisions index**: `bin/cosmic _docs/derive.tl`
   rewrites the derived table in `docs/decisions/README.md`, which
   `_build/docs_test.tl` gates. Commit the rewritten README. If any
   ratchet gate complains, run exactly the regen command its failure
   message prints and commit that result — never weaken a gate any
   other way.

## Non-goals

- **Do NOT change `TRIAGE_K`** (`_perf/compare.tl:27`, `2.0`) or
  `DEFAULT_THRESHOLD_PCT` (`_perf/compare.tl:19`, `10.0`). Widening
  either is the "weaken it until it passes" move this item exists to
  avoid, and it would excuse base64's real +21%.
- **Do NOT add a noise-excused scenario set**, a per-scenario
  allowlist, or any per-name special case anywhere in `_perf/`.
- **Do NOT weaken, rename, resize, or remove any scenario or its
  `check()`** — not `json_decode_large`, not
  `codec_base64_roundtrip_64k`, not any of the other six the A/A
  flagged. The `optimize` skill's standing rule.
- **Do NOT commit a per-scenario noise profile file.** The record in
  (1) rejects it explicitly; adding one here would contradict the
  record landing in the same diff.
- **Do NOT change `triage`'s existing signature**, `_perf/run.tl`, or
  any of the seven existing `compare.triage` call sites in
  `_perf/compare_test.tl`. They pin today's two-control behaviour and
  must keep passing unmodified.
- **Do NOT change `identity_refusal` or its two existing call sites'
  refusals** (`_perf/gate.tl:118`, `164`). A control whose binary does
  not match is dropped from the control set, never silently trusted.
- **Do NOT edit `.github/workflows/release.yml`.** The three
  measurements this slice consumes are already taken there; no
  workflow change is needed and none is in scope.
- **Do NOT dispatch `release.yml` with `perf_gate: false`.** It
  publishes a release outward. It is a human's call and it should wait
  on `3ISlWFiS`.
- **Do NOT touch the cosmos pin** or `bin/cosmic.pin`.
- **No `o/perf/*.json` is committed.**

## Acceptance

Run from the cosmic repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _perf/compare_test.tl` passes and reports
  `_perf/compare_test.tl (N test functions)` where N is two more than
  today. Measure today's count first with the same command and quote
  both numbers in the PR description.
- `bin/cosmic --make test _perf/gate_test.tl` passes and reports one
  more test function than today, measured and quoted the same way.
- **The new gate test discriminates.** With change (3) reverted and
  changes (2), (4) and (5) kept,
  `bin/cosmic --make test _perf/gate_test.tl` FAILS. State in the PR
  description that this was checked and quote the failure.
- **The asymmetry holds, both directions.** Both new
  `_perf/compare_test.tl` functions pass: the `json_decode_large`
  fixture reclassifies to `noise`, the `codec_base64_roundtrip_64k`
  fixture stays `regression`. Quote both assertions' scenarios in the
  PR description.
- `grep -c 'triage_many' _perf/compare.tl` → at least `4` (today: `0`).
- `bin/cosmic --make test _build/docs_test.tl` passes — the D31 row is
  in `docs/decisions/README.md` and matches the record's H1.
- `grep -c '^# D31 — ' docs/decisions/d31-gate-noise-from-every-control-pair.md`
  → `1`.
- `grep -c 'TRIAGE_K = 2.0' _perf/compare.tl` → `1` (unchanged), and
  `grep -c 'DEFAULT_THRESHOLD_PCT = 10.0' _perf/compare.tl` → `1`
  (unchanged).
- `git diff --name-only origin/main...HEAD` names no file under
  `.github/`, no `3p/cosmos/cosmos_pin.tl`, no `bin/cosmic.pin`, and
  no `o/`.
- `wc -l _perf/compare.tl _perf/compare_test.tl _perf/gate.tl
  _perf/gate_test.tl` — all four ≤ 500 (today: 316, 264, 304, 366).

## Enablement

`none needed`. Every mechanism this slice uses already exists and is
already exercised in the files it touches: `compare.diff` and
`compare.triage` are in `_perf/compare.tl`, `identity_refusal` and the
three-measurement `gate_inner` path are in `_perf/gate.tl`,
`_perf/gate_test.tl` already drives `gate` through that full path with
a `measure` stub at thirteen call sites, and `bin/cosmic
_docs/derive.tl` is the regen command `_build/docs_test.tl`'s own
failure message prints. The decision record's form is
`skills/decide/SKILL.md` with `docs/decisions/d29-tests-run-because-defined.md`
as the nearest-shaped example.

The one judgment a literal-minded session could get wrong — extending
`triage` in place and breaking its nine callers — is walled in
`Non-goals` and checked by the requirement that the seven existing
`compare_test.tl` call sites pass unmodified.

Two related items stay open and are NOT this slice's: `3ISlWFiS`
carries base64's real regression against whilp/cosmopolitan, and
`3ISVlHT6` (the pin bump) waits on both. Landing this slice alone does
not turn the release lane green — base64 still fails it, correctly.
