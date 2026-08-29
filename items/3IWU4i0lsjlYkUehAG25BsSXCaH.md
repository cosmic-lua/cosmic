## Goal

G6 — every release measures the defining paths and answers for them
(this item's parent, `3HyRcd9F`). The compare gate must not publish a
regression it flagged once and then dismissed with no evidence that the
dismissal was noise.

## Change

Teach the compare gate to demand evidence for a DISMISSAL: a regression
pass 1 flagged that pass 2 read quiet stands unless the same-binary
controls explain the disagreement. `_perf/compare.tl`, `_perf/gate.tl`
and `_perf/gate_strike_test.tl` change; `_perf/reproduce.tl` and
`_perf/reproduce_test.tl` are new; one decision record is added and D34's
closing paragraph amended. The sections below give the defect, the rule,
the alternatives it beats, and each file's edit.

### The defect, reproduced end to end today

`gate_inner` ends the compare gate the moment pass 2 reads clean
(`_perf/gate.tl`, the `if failures == 0 then return 0 end` after pass 2's
`compare_once`). A regression pass 1 flagged that reads quiet on the
retry is DISMISSED — silently, on two current-side samples, with no
control consulted and no message printed — while a regression that flags
twice earns a third sample and magnitude-aware triage across three
control pairs.

Measured 2026-08-28 against `origin/main@40776231` ("release.yml: gate
that the peers lane measures this run's own binary (#1488)"; the tip that
carries `3ff022d3`, #1487 and #1488). A throwaway worktree at that
commit, with one probe test copied in that drives `gate.gate` with a
fabricated scenario reading 1.00 µs baseline, 1.12 µs in pass 1 (+12.0%,
over the 10% bar) and 1.09 µs on the retry (+9.0%, under it), the two
current-side files naming the same `bin_sha`:

```text
a                                 1.00 µs ->      1.12 µs    +12.0%  (noise  ±10.0%)  regression
perf-compare: regression flagged; re-measuring once into .../borderline-cur-retry.json to filter noise
a                                 1.00 µs ->      1.09 µs     +9.0%  (noise  ±10.0%)  ok
1 scenarios: 0 regression, 0 faster, 1 ok, ...
perf-compare: PASS
PROBE code=0 calls=1
```

**Re-measured at pull, 2026-08-29**, against `origin/main@29011923`
("skills/work: the orchestrator may take the verdict on its own wave
(#1494)") — the tree that now carries both blockers, #1485 and #1486,
merged. The same probe answers `PROBE code=0 calls=1` with the same two
rows, each now preceded by #1485's `binaries: base aaaa1111  current
bbbb2222  (differ)` header. The defect is unchanged.

Both samples say the scenario is up by roughly a tenth; one fell under
the bar and the gate published. `release.yml` re-baselines to the
PREVIOUS RELEASE's binary daily, so the escape is absorbed into
tomorrow's baseline and never re-asked.

### The rule this change installs

A pass-1 flag that pass 2's table does not carry as a regression is a
DISMISSAL. After this change a dismissal is credible only when the
same-binary controls show that scenario swinging by enough to explain the
two samples disagreeing — the SAME credit rule `triage_many` already
applies (`_perf/compare.tl`): absorbed when
`|pass-1 delta| <= max(pass-1 noise_pct, TRIAGE_K * |loudest control delta|)`,
`TRIAGE_K = 2`. An unexplained dismissal has its pass-2 verdict amended
back to `regression`, its message printed, and — because the amendment
happens before the early exit — escalates to the A/A self-check and full
triage like any other persisting regression.

The controls read are the two current-side samples the gate already has
on disk (`opts.current` and the retry). **This buys no measurement on the
clean path**: the A/A control the item's title says is missing was there
all along, unread — it is the disagreement itself.

What actually changes, in closed form. With noise bar `N`, pass-1 delta
`f > N`, pass-2 delta `r <= N`, and the control pair reading `c ≈ f - r`,
the dismissal is unexplained exactly when `f > max(N, 2c)`, i.e.
`N < f < 2r`. At `N = 10` that is `f` in (10, 20) with `r` in (5, 10]:
both current-side samples agree the scenario is up and one merely fell
under the bar. Every other dismissal — the loud, genuinely
non-reproducing kind — is absorbed exactly as today.

### Why this fix and not the two the capture listed

- **"a third current-side pass when pass 2 is quiet"** — costs a full
  measurement pass inside a release step already carrying
  `timeout-minutes: 15`, and leaves the decision rule open: the obvious
  2-of-3 majority reclassifies `b` in
  `_perf/gate_strike_test.tl:test_strike_once_regression_reclassifies_and_passes`
  (`selfb` repeats the retry's numbers there, so `b` flags in 2 of 3),
  reinstating the historical false red that test pins. This fix takes a
  third sample only in the narrow band above, and only after the
  dismissal is already unexplained.
- **"read the A/A control unconditionally and triage BOTH passes"** —
  triaging both passes and failing on either is the union rule, which is
  D34's second rejected option and which the same
  `test_strike_once_regression_reclassifies_and_passes` refuses.
- **the baseline-pair credit** (D34's third rejected option, exported as
  a `triage_many` second control GROUP) is item `3IWx3I4Z` and is a
  Non-goal here. This fix does not need it: every control it reads is a
  current-side pair, so no baseline-versus-current pair — the comparison
  under test — is ever formed, which is the exact objection that made
  the baseline-pair option a separate slice.

### Files

Line numbers below were written against the MERGED tree (`origin/main` +
`origin/claude/3IUBNQZZ-compare-rows` +
`origin/claude/3IVLAF3Z-stampless-identity-v2`, tree
`e95e5f821a75284314b5bf9c44ee358dc35f5ee1`). **Re-measured at pull,
2026-08-29:** both blockers have LANDED, so that merged tree is now
plain `origin/main@29011923` and every file length below re-measures
identically (gate 490, compare 416, gate_strike_test 214, gate_test 382,
compare_test 360). Two line-number citations shifted by one and are
corrected in place; nothing else moved.

1. **`_perf/compare.tl`** — export the existing `loudest_control`
   (defined at `:161` on `origin/main`; no behaviour change). Add the
   field to the `compare` record IMMEDIATELY AFTER `triage_many:` and the
   entry to `M` IMMEDIATELY AFTER `triage_many = triage_many,`. That
   position is load-bearing: measured below, beside `load_results` it
   conflicts with `3IVLAF3Z`'s hunk and beside `triage_many` it does not.
   `grep -c loudest_control _perf/compare.tl` is 2 on the merged tree and
   must read 4 after.

2. **`_perf/reproduce.tl`** — NEW module, the reproduction rule in one
   place, both directions:
   - `restore(deltas: {pt.Delta}, flagged: {string: pt.Delta}, controls:
     {pt.Results}, threshold: number): {string}` — walk `deltas` (array
     order, so the output is deterministic; never `pairs` over `flagged`).
     For each delta whose name is in `flagged` and whose verdict is `ok`
     or `faster`, apply the absorb rule above against
     `compare.loudest_control(controls, threshold)`; when it does not
     absorb, set `d.verdict = "regression"` and append the message
     `perf-compare: <name> flagged in pass 1 and read quiet on the retry,
     but no same-binary control explains the gap -- counted as a
     regression`. Copy `delta_pct` / `noise_pct` to locals before
     guarding — record FIELDS do not narrow.
   - `restore_paths(deltas, flagged, control_paths: {string}, threshold)`
     — `restore` over paths, loading each with `compare.load_results` and
     dropping one that will not load (which only removes noise credit;
     the file is the next call's error to report, the same reasoning
     `identity_refusal` uses).
   - `reconcile(deltas, flagged, control_paths, threshold, same_side:
     boolean): {string}, integer` — the strike-twice reclassification
     loop MOVED here from `_perf/gate.tl:304-315` (a regression standing
     that pass 1 did not flag becomes `noise`), followed by
     `restore_paths` when `same_side`. Returns the messages to print and
     the change to the caller's failure count.

3. **`_perf/gate.tl`** —
   - `flagged_first` becomes `{string: pt.Delta}` (was
     `{string: boolean}`); both `flagged_first[d.name] = true` become
     `= d`. The strike-twice test `flagged[d.name] == nil` reads the same.
     The pass-1 MAGNITUDE is what the absorb rule needs and the boolean
     threw it away.
   - after the retry (and, when `--baseline-bin` is given, after the
     baseline retry and its identity check), `local same_side =
     same_binary(opts.current, retry)`; when true, print each message
     from `reproduce.restore_paths(deltas, flagged_first, {opts.current,
     retry}, opts.threshold)` and add one failure each — placed BEFORE
     pass 2's `print_report(base_side, retry, deltas)` and before the
     `if failures == 0 then return 0 end` early exit, so the printed
     table carries the amended verdicts (D34's rule that a verdict the
     gate would not act on may not stand in the record) and an
     unexplained dismissal escalates.
   - the strike-twice loop at `:304-315` is replaced by one
     `reproduce.reconcile(deltas, flagged_first, controls, opts.threshold,
     same_side)` call whose messages are printed and whose integer is
     added to `failures`.
   - `same_side` gates the rule because two current-side samples are only
     comparable to each other when they measured the same binary; the
     helper is `same_binary`, which `3IVLAF3Z` introduces and which
     refuses a stampless pair.
   - the module header paragraph beginning "The sampling is asymmetric,
     and this module does not fix that" is rewritten to state the rule
     that now holds.

4. **`_perf/reproduce_test.tl`** — NEW, unit tests over `restore` and
   `reconcile` with fabricated `Results`: absorbed vs unabsorbed
   dismissal, a dismissal with no control pair, deterministic message
   order, and that a `missing`/`error` verdict is never rewritten.

5. **`_perf/gate_strike_test.tl`** — four end-to-end tests, added to the
   seven already there (214 lines, `wc -l`, unchanged by both open PRs):
   - `test_two_agreeing_samples_straddling_the_bar_fail` — base 1000, cur
     1120, retry 1090, one `bin_sha` on both current-side files. **This
     is the mutation test: it fails before the change and passes after**
     (measured below).
   - `test_a_noisy_dismissal_still_passes` — base 1000, cur 1300, retry
     1000: the control pair reads -23.1%, the +30.0% flag is absorbed,
     code 0.
   - `test_a_third_sample_absorbs_an_unexplained_dismissal` — the
     borderline numbers with `selfcheck_b` reading 1300, so the fuller
     control set credits the scenario and the gate passes: the
     false-red guard, and the reason escalation is the right response.
   - `test_a_dismissal_with_no_same_binary_pair_stands` — cur and retry
     naming different binaries: `same_side` is false, the rule is off,
     code 0.

6. **`docs/decisions/dNN-*.md` + `docs/decisions/README.md`** — a NEW
   record (not an amendment): D34's decision — which baseline the
   reproduction question is asked against — is untouched; this settles a
   different question, what evidence a DISMISSAL must carry, and accepts
   a new false-red class, so it earns its own record under
   `skills/decide/SKILL.md`. Take the next free number after checking
   every remote branch, not just `main` (`d34` is the highest anywhere as
   of 2026-08-28; `for b in $(git branch -r --format='%(refname:short)' |
   grep -v HEAD); do git ls-tree --name-only $b docs/decisions/; done`).
   Amend ONLY D34's closing "What this does NOT fix" paragraph to point
   at the new record; leave its decision and its three rejected options
   as written. Regenerate the index with `bin/cosmic _docs/derive.tl`.

### Measured facts, 2026-08-28 (re-measured at pull, 2026-08-29)

Every number below was produced by the command beside it, on one
container. **Re-measured at pull:** `origin/main` is now `29011923` and
carries both blockers merged, so the "merged" column below IS
`origin/main` today and every one of its lengths re-reads unchanged —
gate 490, compare 416, gate_strike_test 214, gate_test 382,
compare_test 360. `grep -c loudest_control _perf/compare.tl` still reads
2, `loudest_control` is still defined at `_perf/compare.tl:161`, and
`grep -c '^local function test_' _perf/gate_strike_test.tl` still reads
7. `d34` is still the highest decision number on every remote branch.

| fact | command | value |
|---|---|---|
| today's main | `git log --oneline -1 origin/main` | `40776231` (now `29011923`) |
| the two open PRs merge cleanly with each other | `git merge-tree --write-tree --messages origin/claude/3IUBNQZZ-compare-rows origin/claude/3IVLAF3Z-stampless-identity-v2` | rc 0, tree `e95e5f82` |
| `_perf/gate.tl` | `git show origin/main:_perf/gate.tl \| wc -l` | 460 |
| `_perf/gate.tl`, merged | `git show e95e5f82:_perf/gate.tl \| wc -l` | **490** (10 under the cap) |
| `_perf/compare.tl` / merged | same, `_perf/compare.tl` | 357 / **416** |
| `_perf/gate_strike_test.tl` / merged | same | 214 / 214 |
| `_perf/gate_test.tl` / merged | same | 380 / 382 |
| `_perf/compare_test.tl` / merged | same | 290 / 360 |

**The line cap is the reason step 2's `reconcile` MOVES the strike-twice
loop rather than leaving it.** A prototype of this change that only ADDED
the restore half took `_perf/gate.tl` to 505 on the merged tree and
`cosmic --check lint _perf/gate.tl` answered
`_perf/gate.tl:501:1: file-length: _perf/gate.tl has 505 lines (limit: 500)`.
Moving the loop into `reproduce.tl` measured `_perf/gate.tl` 493,
`_perf/reproduce.tl` 104, `_perf/compare.tl` 418 — 7 lines of headroom,
which is thin. If the implementation cannot hold `_perf/gate.tl` at 500
or under, that is a bounce, not a licence to widen the cap: file the
extraction of `main`'s `measure` / `measure_baseline` closures
(`_perf/gate.tl:409-452` on the merged tree, ~48 lines) as its own item
and block this one on it.

That thinness is already a filed capture: `3IYCQxfH` (`backlog`,
"`_perf/gate.tl` reaches 490/500 once the two PRs in check merge, and
three open items want to edit it"). This item does NOT wait on it — the
measured 493 fits — but it does spend most of what is left, and
`3IYCQxfH` counts `3IWx3I4Z`'s smallest plumbing at +9 lines, which lands
at 502 on top of this change. Say so in the PR description so the split
is sequenced deliberately rather than discovered by the next red lint.

**The prototype ran green.** On the merged tree, with the shape described
above plus the probe:
`cosmic --make test _perf/probe_test.tl _perf/gate_strike_test.tl _perf/gate_test.tl _perf/compare_test.tl`
→ `49 tests: 49 passed` / `test: PASS (4 files)`. All seven existing
strike tests and all 17 `gate_test` tests pass unchanged — including
`test_strike_once_regression_reclassifies_and_passes`,
`test_a_one_off_fast_baseline_retry_fails_the_gate` and
`test_current_side_instability_absorbs_the_fast_baseline_retry`, whose
dismissals are either absorbed by their (cur, retry) control or excluded
by `same_side`.

**The machine's A/A floor, re-measured today** — the item's previous
reading (14 of 48, loudest +62.2%) does NOT reproduce.
`bin/cosmic --make run _perf/gate.tl selfcheck o/perf/aa1.json
o/perf/aa2.json` at `origin/main@40776231`:

```text
48 scenarios: 3 regression, 3 faster, 42 ok, 0 noise, 0 new, 0 missing, 0 error, 0 baseline-error, 0 malformed
perf-selfcheck: the scenarios flagged above vary by more than the bar on noise alone
```

Six of 48 past the bar, loudest `sqlite_point_query` +15.7%,
`url_decode_query_value` +13.7%, `literal_format_floor_compact` +12.6%,
`hash_sha256_small` -16.2%. D34 records 13 of 48 at up to +95.1% and the
original capture 14 of 48 at up to +62.2%, so the count swings 6..14
within a day on the same container. Two consequences, both stated
deliberately: the escape this item closes is not exotic (a quiet second
sample is routine), and the false red this rule accepts is real, because
today's loudest A/A swings (12.6..15.7%) sit inside the `f` in (10, 20)
band where the rule fires. The guard is the escalation: a scenario that
noisy normally shows it across the three control pairs the third sample
opens, which is what
`test_a_third_sample_absorbs_an_unexplained_dismissal` pins. When it does
not, the cost is one workflow re-run — the same asymmetry D34 settled: a
false red costs a re-run and `release.yml` already prints that remedy; a
false green is absorbed into tomorrow's baseline forever.

## Non-goals

- **Do not give the BASELINE pair its own noise credit** and do not add a
  second control GROUP to `triage_many`. That is item `3IWx3I4Z` and
  D34's third rejected option. This change reads only current-side
  pairs. It does export `loudest_control`, which `3IWx3I4Z` also expects
  to need — that half is settled here, and `3IWx3I4Z` inherits it.
- **Do not change `TRIAGE_K`, `DEFAULT_THRESHOLD_PCT`, or `diff`'s
  verdict vocabulary.** D31 governs how much variance a scenario is
  credited for and stands unamended; this change adds a new PLACE the
  existing credit is read, not a new credit.
- **Do not change the union rule.** A regression flagging only in the
  retry still reclassifies to `noise` with no control requirement
  (D34's second rejected option;
  `test_strike_once_regression_reclassifies_and_passes` pins it). The
  loop moves file; its logic does not move an inch.
- **Do not weaken, renumber, or delete any
  existing test** in `_perf/gate_strike_test.tl`, `_perf/gate_test.tl` or
  `_perf/compare_test.tl`. All 49 pass against the prototype; a red one
  is a defect in the change.
- **Do not touch `.github/workflows/release.yml`, `_perf/run.tl`,
  `_perf/baserun.tl`, `_perf/baseline.tl`, or `_perf/harness.tl`.** The
  gate's CLI, its `--baseline-bin` flag and its one caller
  (`release.yml`) are unchanged, and so is the number of measurement
  passes on the clean path (pass 1 alone) and on the flag-twice path
  (three).
- **Frozen output contracts**: the `perf-compare: PASS` / `perf-compare:
  FAIL` verdict lines, `compare.format_delta`'s row layout and
  `compare.format`'s summary line are parsed downstream — do not change
  them. New text is added only as new `perf-compare:` message lines.
- **Do not widen the 500-line cap, add a lint exemption, or split a file
  beyond `_perf/reproduce.tl`.**
- Do not touch `.cosmic-coverage` except by running the exact regen
  command a coverage-ratchet failure prints, and commit that result.

## Acceptance

Run from the repo root. None writes into the committed tree.

1. `bin/cosmic --make ci` ends `ci: PASS` (5 stages: fmt, check, example,
   lint, coverage).
2. `bin/cosmic --make test _perf/gate_strike_test.tl _perf/gate_test.tl _perf/reproduce_test.tl _perf/compare_test.tl`
   ends `test: PASS (4 files)`, with `_perf/gate_strike_test.tl` reporting
   11 test functions (7 today, `grep -c '^local function test_' _perf/gate_strike_test.tl`).
3. **The mutation test.** Against the change's own base commit, with only
   the new test file copied in, `test_two_agreeing_samples_straddling_the_bar_fail`
   must FAIL and the other ten pass:

   ```sh
   git worktree add /tmp/pre-3IWU4i0l "$(git merge-base HEAD origin/main)"
   mkdir -p /tmp/pre-3IWU4i0l/o && cp -r o/3p o/bootstrap /tmp/pre-3IWU4i0l/o/
   cp _perf/gate_strike_test.tl /tmp/pre-3IWU4i0l/_perf/
   (cd /tmp/pre-3IWU4i0l && "$OLDPWD"/o/bin/cosmic --make test _perf/gate_strike_test.tl)
   git worktree remove --force /tmp/pre-3IWU4i0l
   ```

   ends `test: FAIL (1 of 1 file)` naming
   `test_two_agreeing_samples_straddling_the_bar_fail`. (The `o/3p` and
   `o/bootstrap` copy is required: without it the fresh worktree's build
   stops at `tlast_gen: o/3p/tl/tl.lua: missing; run 'cosmic --make fetch'
   first`, and `--make fetch` needs a network.)
4. Line caps — the bound is the contract, not the prose:
   - `wc -l < _perf/gate.tl` ≤ 500 (490 before this change; 493 measured
     on the prototype)
   - `wc -l < _perf/compare.tl` ≤ 500 (416 before; 418 measured)
   - `wc -l < _perf/reproduce.tl` ≤ 200 (104 measured)
   - `wc -l < _perf/gate_strike_test.tl` ≤ 400 (214 before)
   - `wc -l < _perf/reproduce_test.tl` ≤ 300
5. Placement and move greps:
   - `grep -c 'reproduce\.' _perf/gate.tl` = 2 (0 before)
   - `grep -c 'flagged only in the retry' _perf/gate.tl` = 0 (1 before)
   - `grep -c 'flagged only in the retry' _perf/reproduce.tl` = 1
   - `grep -c loudest_control _perf/compare.tl` = 4 (2 before)
   - `grep -c 'flagged_first' _perf/gate.tl` = 5 (5 before — the count is
     unchanged; the TYPE is what moves)
6. `bin/cosmic _docs/derive.tl && bin/cosmic --make test _build/docs_test.tl`
   ends `test: PASS (1 file)` with the new record in
   `docs/decisions/README.md`.
7. `git diff origin/main --name-only` lists exactly: `_perf/compare.tl`,
   `_perf/gate.tl`, `_perf/reproduce.tl`, `_perf/reproduce_test.tl`,
   `_perf/gate_strike_test.tl`, `docs/decisions/dNN-*.md`,
   `docs/decisions/README.md` — nothing under `o/`.

## Enablement

**Blocked on two in-flight items, both measured, both `check` with open
PRs.** Recorded in `blocked_by`.

- **`3IUBNQZZ` (PR #1485, `claude/3IUBNQZZ-compare-rows`)** — a real
  textual conflict in `_perf/gate.tl` that no insertion point avoids. A
  prototype of this change committed on `origin/main@40776231`:

  ```text
  $ git merge-tree --write-tree --messages <proto> origin/claude/3IUBNQZZ-compare-rows
  rc=1
  Auto-merging _perf/compare.tl
  Auto-merging _perf/gate.tl
  CONFLICT (content): Merge conflict in _perf/gate.tl
  ```

  Both of this change's insertion points sit immediately above a
  `print(compare.format(deltas))` line that #1485 rewrites to
  `print_report(...)`, and neither can move: the restore must run after
  the pass's `compare_once` (it needs `deltas`) and before the print (the
  printed table is the record and must carry the amended verdicts).
  Relocation was tried and does not exist. Land #1485 first.

- **`3IVLAF3Z` (PR #1486, `claude/3IVLAF3Z-stampless-identity-v2`)** — an
  API dependency, not a conflict. The `same_side` guard is
  `same_binary(opts.current, retry)`, the helper #1486 adds to
  `_perf/gate.tl` over `compare.same_binary`. Without it the guard would
  be `identity_refusal(...) == nil`, which #1486 measured to admit
  STAMPLESS pairs as same-binary — a pair that names no binary would turn
  this rule on and, with no control credit, restore every dismissal.

  This one is NOT a merge conflict, given the insertion point named in
  `Change` step 1. Measured both ways on the same prototype: with the
  `loudest_control` export beside `load_results`,
  `git merge-tree --write-tree --messages <proto> origin/claude/3IVLAF3Z-stampless-identity-v2`
  returns rc=1 with `CONFLICT (content): Merge conflict in
  _perf/compare.tl` (#1486 inserts `same_binary` in the same two slots);
  moved beside `triage_many`, the same command returns **rc=0,
  `Auto-merging _perf/compare.tl`, `Auto-merging _perf/gate.tl`**. That
  is why the insertion point is written into `Change` rather than left to
  the builder.

**Nothing else is missing.** `compare.loudest_control` and
`compare.TRIAGE_K` already implement the credit rule; `pt.Delta` already
carries `delta_pct` and `noise_pct`; `_perf/gate_strike_test.tl` already
has the `write_multi` / `paths` fixtures the four new tests need, with
`bin_sha` as a parameter. No new lint, fixture or gate is needed — the
mutation test in `Acceptance` step 3 is the countermeasure, and it is
cited there rather than assumed.

**Re-run every measured command above at pull.** `origin/main` moved four
times on 2026-08-28 alone, and the A/A floor moved from 14-of-48 to
6-of-48 within the same day; the merged line counts in particular must be
re-measured against whatever `origin/main` carries once #1485 and #1486
have landed.
