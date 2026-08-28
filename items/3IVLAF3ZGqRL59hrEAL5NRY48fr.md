## Goal
G6 — the defining paths, ratcheted (parent `3HyRcd9F`). The perf gate is
one of those paths: it refuses to publish a release whose scenarios
regressed, and it separates a real regression from machine variance with
same-binary A/A controls. This slice makes the identity precondition
under those controls real instead of vacuous.

## Problem (measured at `origin/main` = `6a4d0182`, 2026-08-28)

`compare.identity_refusal` (`_perf/compare.tl:306-331`) answers two
questions with one function, and returns `nil` — "the pair is sound" —
whenever either file lacks `meta.bin_sha` (`_perf/compare.tl:310-315`).
`_perf/gate.tl:230` then reads that `nil` as proof of sameness:

```teal
local controls = {retry, opts.selfcheck_b}
if identity_refusal(retry, opts.current, true) == nil then
  table.insert(controls, 1, opts.current)
end
```

so a `current` with no stamp is admitted as a SAME-BINARY noise control.
The comment directly above it (`_perf/gate.tl:225-228`) promises the
opposite — "`current` joins the controls only when it names the SAME
binary as the retry" — and so does D31's decision text ("admitting
`current` to the control set only when it names the same binary as the
retry"). A stampless file names no binary at all, so the code does not
implement its own comment or its own record. The same vacuity sits under
the three refusals that assert sameness — `_perf/gate.tl:179` (baseline
retry), `:212` (the A/A control pair), `:280` (`selfcheck`).

**The constructed case.** Driver: `base` stamped `aaaa1111` at 1000ns;
`current` at 2000ns; the injected `measure` writes `retry` 1400ns and
`selfcheck_b` 1390ns, both stamped `bbbb2222`. The ONLY variable is
whether `current` carries a stamp. Run against `origin/main`'s
`_perf/gate.tl` loaded from the tree (`_perf` ships inside the binary, so
the driver required a renamed copy of the tree's `_perf` to be sure it
read main's code, verified byte-identical modulo the package name):

```text
=== stampless current ===
perf: .../cur.json does not record which binary it measured, so these two runs cannot be told apart
scenario   1.00 µs ->   2.00 µs   +100.0%  (noise ±10.0%)  regression
perf-compare: regression flagged; re-measuring once into .../cur-retry.json to filter noise
scenario   1.00 µs ->   1.40 µs    +40.0%  (noise ±10.0%)  regression
perf-compare: regression persists; running A/A self-check to separate real regressions from machine noise
perf: .../cur.json does not record which binary it measured, so these two runs cannot be told apart
scenario   1.00 µs ->   1.40 µs    +40.0%  (noise ±10.0%)  noise
perf-compare: PASS                          <-- exit 0

=== the same file, stamped with a foreign binary (cccc3333) ===
scenario   1.00 µs ->   1.40 µs    +40.0%  (noise ±10.0%)  regression
perf: 1 scenario(s) regressed, errored, or went missing
perf-compare: FAIL                          <-- exit 1
```

A +40% regression that struck in BOTH passes is relabelled `noise` and
the gate passes, because the stampless `current` (measured 2000ns) paired
against the retry (1400ns) donates a -30% "control swing", and
`|40| <= TRIAGE_K * |30|`. Stamping the same file with a foreign sha
drops it from the controls and the gate correctly fails. The stderr
warning is printed both times and changes nothing — exactly the
"a warning above a plausible-looking table gets read past" failure
`_perf/compare.tl:284-286` says the refusals exist to prevent.

**How a stampless file arises: by hand, not from a lane.** `run.tl`
stamps from `fs.read(meta.bin)` where `meta.bin` is
`PERF_BIN or arg[-1]` (`_perf/run.tl:131-147`). Measured under
`o/bin/cosmic`: `arg[-1]` is absolutised by cosmopolitan even for a
PATH-resolved bare name (`cosmic zz.tl` -> `/home/user/cosmic/o/bin/cosmic`,
readable), `--make run` spawns the target with an ABSOLUTE cosmic path
(`_make/runverb.tl`'s `child_argv = {cosmic, target_lua}`), and
`bin/cosmic` execs `${ROOT}/o/bin/cosmic` absolute. All four documented
commands and both `release.yml` perf invocations
(`release.yml:139-140`, `:181`) therefore stamp. The reachable triggers
are: `PERF_BIN` pointed at an unreadable path (verified:
`PERF_BIN=/no/such/binary` -> `readable=false` -> no stamp), a results
file predating the field (`bin_sha` landed 2026-08-26 in #1432, commit
`102fe9f2`), and any hand-written or archived JSON handed to
`gate.tl compare` / `run.tl --compare`, which take arbitrary paths.
**Verdict: latent, not live** — no CI lane can produce a stampless file
today. It is worth fixing anyway because the guard's whole job is to be
non-vacuous the day one does arrive, and because the code contradicts
D31's stated decision.

**The fix, and what each direction costs.** Two options were weighed.
Refusing a stampless file outright as a gate INPUT is the eager
direction: it would turn `run.tl --compare` over an archived pre-#1432
results file into a hard failure, break
`test_a_file_without_a_sha_is_not_refused`, and block a release on a
metadata gap rather than on a measurement — the expensive failure
direction `skills/optimize/measurement.md` warns about. Admitting freely
is today's hole and hides real regressions. The pick splits by which
question is being asked, because absence is asymmetric evidence: an
absent stamp can never PROVE two files measured the same binary, but it
is also no evidence that they measured the same binary, so it cannot
falsify a distinctness claim either.

- `same = false` (baseline vs current must DIFFER): unchanged — warn on
  stderr and proceed. Archived and legacy results stay comparable.
- `same = true` (a pair the gate itself measured and requires to match):
  refuse. Those pairs are freshly written by the gate's own `measure`,
  so a missing stamp there means the running binary could not identify
  itself; the operator gets a named cause instead of a fabricated noise
  floor.
- control ADMISSION (`_perf/gate.tl:230`): drop, never refuse — which is
  what the existing comment already promises ("a control lost, not a
  refusal ... dropping `current` leaves exactly the one pair the gate
  read before").

## Change

1. `_perf/compare.tl` (357 lines on main; `wc -l < _perf/compare.tl` = 357,
   143 lines of headroom under the 500-line cap). Add, immediately above
   the `identity_refusal` doc block:

   ```teal
   local function same_binary(a_res: pt.Results, b_res: pt.Results): boolean
     local sa = a_res.meta and a_res.meta.bin_sha
     local sb = b_res.meta and b_res.meta.bin_sha
     return sa ~= nil and sb ~= nil and sa == sb
   end
   ```

   with a `---` doc comment saying that absence is never proof, and that
   the predicate is positive because reading
   `identity_refusal(...) == nil` as "same binary" is what admitted
   stampless files. Declare `same_binary: function(a_res: pt.Results,
   b_res: pt.Results): boolean` on the `compare` record and export it on
   `M` (`grep -c "same_binary" _perf/compare.tl` is 0 today).

2. `_perf/compare.tl`, inside `identity_refusal`'s `if not sa or not sb
   then` branch (`:310-315`): keep the existing stderr line, then, when
   `same` is true, RETURN a refusal string instead of `nil`. Wording:
   name both paths and say that an unidentified pair is not a noise
   floor. When `same` is false, still `return nil`. Extend the function's
   doc comment (`:297-299`) to state the asymmetry: absence cannot prove
   sameness, and is not evidence of difference either.

3. `_perf/gate.tl` (406 lines; `wc -l < _perf/gate.tl` = 406, 94 lines of
   headroom). Add a path-level `same_binary(a: string, b: string): boolean`
   beside the existing path-level `identity_refusal` (which ends at
   `:111`) — insert it directly above the `--- Print the gate's verdict`
   doc block at `:113`. It loads both files with `compare.load_results`,
   returns `false` when either fails to load, else
   `compare.same_binary(ra, rb)`.

4. `_perf/gate.tl:230`: replace
   `if identity_refusal(retry, opts.current, true) == nil then` with
   `if same_binary(retry, opts.current) then`. Leave the comment at
   `:225-228` as it stands — it now describes the code.

5. `_perf/gate_test.tl` (479 lines; only 21 of headroom, so this slice
   adds NO lines to it). Five existing tests fabricate stampless
   fixtures and reach the A/A path, where they would now hit the new
   refusal or lose a control. Stamp their fixtures IN PLACE — add a
   third argument to the existing `write_results` calls, changing no
   assertion and no expected exit code: the `base` file gets
   `"aaaa1111"`, the `cur` file and every file the injected `measure`
   writes get `"bbbb2222"`. The five, by name:
   `test_persistent_regression_triaged_as_noise_passes` (`:99`),
   `test_large_regression_survives_unstable_selfcheck_and_fails` (`:131`),
   `test_real_regression_survives_triage_and_fails` (`:154`),
   `test_selfcheck_reports_quiet_and_noisy` (`:188`),
   `test_the_gate_triages_against_every_measured_control` (`:360`).
   `test_selfcheck_reports_quiet_and_noisy` has no base/cur pair — it is
   an A/A run, so BOTH of its files (`out == a and 1000 or 1010`, and
   the `1500` in its second `gate.selfcheck` call) get `"bbbb2222"`.
   The two `write_results(out, ...)` lines inside
   `test_the_gate_triages_against_every_measured_control` carry trailing
   comments and cross 90 columns once the argument is added (measured on
   the prototype at 91 and 95 columns, against
   `git show origin/main:_perf/gate_test.tl | awk 'length>90' | wc -l`
   = 0 today) — move those two comments onto their own line above.
   Touch nothing else in
   this file; in particular leave `test_a_file_without_a_sha_is_not_refused`
   (`:340`) exactly as it is, since the `same = false` behaviour it pins
   does not change.

6. New file `_perf/gate_identity_test.tl` (~95 lines), holding the
   binary-identity rules, in the same style as `_perf/gate_test.tl` and
   with its own local `write_results` / `paths` helpers (do NOT
   `require` the other test file). Four tests:
   - `test_a_stampless_current_is_not_a_control` — the constructed case
     above verbatim: `base` `"aaaa1111"` 1000, `cur` stampless 2000,
     `measure` writes 1400 then 1390 both `"bbbb2222"`; asserts
     `code == 1` and `calls == 2`.
   - `test_a_stampless_aa_pair_is_not_a_noise_floor` — `base`
     `"aaaa1111"` 1000, `cur` `"bbbb2222"` 1300, `measure` writes
     stampless 1300 then stampless 1800 (a swing that would otherwise
     buy the +30% full credit); asserts `code == 1`.
   - `test_stampless_selfcheck_refuses` — `gate.selfcheck` whose
     `measure` writes stampless 1000 and 1010; asserts `code == 1`.
   - `test_a_control_that_will_not_load_is_not_admitted` — `base`
     `"aaaa1111"` 1000, `cur` `"bbbb2222"` 2000, and the second
     `measure` call removes `cur` after writing its own output; asserts
     `code == 1`. This one covers the load-failure branch of the new
     helper; the first three are the ones that fail without the fix.
   Define the tests only — write NO `test_x()` self-call lines. D29 is
   active and the neighbouring file has none
   (`grep -c "^test_" _perf/gate_test.tl` = 0).

7. If the coverage ratchet complains, run exactly the regeneration
   command its failure message prints and commit the result. Never lower
   a floor to accommodate an uncovered new branch — cover it instead.

**Composition with the two unreviewed PRs that touch `_perf/gate.tl`.**
Verified with `git merge-tree --write-tree` from a scratch commit
carrying this exact change, at `origin/main` = `6a4d0182`:

- `origin/claude/3IVF3HbV-perf-scoped-manifest` (#1480) — **clean**
  (rc=0). It rewrites only `measure_baseline`'s argv construction inside
  `main()` (`_perf/gate.tl:349+`, through the new `_perf/baserun.tl`);
  disjoint from both sites this slice edits.
- `origin/claude/3IVL9t0P-strike-twice` (#1483) — **clean** (rc=0) as
  specified. Its `_perf/gate.tl` edits are the module doc comment and a
  `base_side ~= opts.baseline` re-key block inserted at `:182`; its only
  change to `_perf/gate_test.tl` is a tail deletion
  (`git diff --numstat origin/main origin/claude/3IVL9t0P-strike-twice --
  _perf/gate_test.tl` -> `0 99`) moving the strike/baseline-retry tests
  into the new `_perf/gate_strike_test.tl`. **This is why step 6 puts the
  new tests in their own file and step 5 adds no lines to
  `_perf/gate_test.tl`**: an earlier prototype that appended the new
  tests to the END of `_perf/gate_test.tl` conflicted with #1483
  (`CONFLICT (content): Merge conflict in _perf/gate_test.tl`), and the
  same change with the tests in their own file merges cleanly against
  both. All five tests step 5 stamps stay in `_perf/gate_test.tl` after
  #1483's split; none move to `_perf/gate_strike_test.tl`, so nothing
  here belongs in that file. No blocker edge is needed in either
  direction.

## Non-goals

- **Do not change the `same = false` behaviour.** A pair where one side
  has no stamp still warns and still compares. `run.tl --compare` over an
  archived pre-#1432 results file must keep working, and
  `test_a_file_without_a_sha_is_not_refused` must keep passing unedited.
- **Do not make `run.tl` refuse to write a stampless results file**, and
  do not change how `meta.bin` / `meta.bin_sha` are derived
  (`_perf/run.tl:118-147`). That is a separate question and belongs to
  `3IVEEDO8` (stamps written but never printed).
- **Do not touch `TRIAGE_K`, `DEFAULT_THRESHOLD_PCT`, `triage`,
  `triage_many`, or `loudest_control`.** D31 froze
  `compare.triage`'s signature (nine callers) and fixed `TRIAGE_K = 2`
  and the 10% bar; this slice changes WHICH runs may be controls, never
  how much credit a control buys.
- **Do not weaken any scenario, functional check, or existing
  assertion.** Every expected exit code in `_perf/gate_test.tl` stays as
  it is; the only edit there is adding a stamp argument.
- **Do not touch `_perf/run.tl`, `_perf/baseline.tl`, `_perf/harness.tl`,
  `_perf/bench/**`, `.github/workflows/release.yml`, or
  `skills/optimize/**`.** No lane's commands change.
- **Do not commit anything under `o/perf/`.**
- **Do not restructure `_perf/gate_test.tl`** beyond the five stamped
  fixtures — #1483 is splitting that file and is unreviewed.

## Acceptance

Run from the repo root. Every command is literally runnable as written.

1. `bin/cosmic --make ci` ends `ci: PASS`.
2. `bin/cosmic --make test _perf/gate_identity_test.tl` passes, running
   all four new tests.
3. `bin/cosmic --make test _perf/gate_test.tl _perf/compare_test.tl`
   passes with no assertion changed.
4. The constructed case fails WITHOUT the fix. This runs the SAME new
   test file against the pre-change sources, entirely under `/tmp`,
   touching no committed file (it costs a cold build and one `fetch`,
   so allow several minutes):

   ```sh
   git worktree add --detach /tmp/gate-premerge $(git merge-base origin/main HEAD) &&
     cp _perf/gate_identity_test.tl /tmp/gate-premerge/_perf/ &&
     (cd /tmp/gate-premerge && bin/cosmic --make fetch &&
      bin/cosmic --make test _perf/gate_identity_test.tl);
     git worktree remove --force /tmp/gate-premerge
   ```

   The inner `--make test` must FAIL, naming
   `a stampless current must not buy noise credit, got 0`. The same file
   passes on this branch (Acceptance 2), which is what makes the test a
   regression pin rather than a description.

5. The new predicate exists and the double-negative admission is gone:
   - `grep -c "same_binary" _perf/compare.tl` is at least 3 (definition,
     record field, export) — it is 0 on `origin/main`.
   - `grep -c "identity_refusal(retry, opts.current, true)" _perf/gate.tl`
     is 0 — it is 1 on `origin/main`.
   - `grep -c "same_binary(retry, opts.current)" _perf/gate.tl` is 1.
6. File-length and style bounds:
   - `wc -l < _perf/gate_identity_test.tl` is at most 120.
   - `wc -l < _perf/gate_test.tl` equals its value on the PR's merge
     base (`git show $(git merge-base origin/main HEAD):_perf/gate_test.tl | wc -l`)
     — this slice adds no lines to that file.
   - `awk 'length>90' _perf/gate_test.tl | wc -l` is 0.
   - `awk 'length>90' _perf/gate_identity_test.tl | wc -l` is 0.
7. The diff touches exactly four paths:
   `git diff origin/main...HEAD --name-only` lists exactly
   `_perf/compare.tl`, `_perf/gate.tl`, `_perf/gate_identity_test.tl`,
   `_perf/gate_test.tl` — plus `.cosmic-coverage` only if step 7 of
   `Change` was needed.
8. Composition still holds at merge time:
   `git merge-tree --write-tree HEAD origin/claude/3IVF3HbV-perf-scoped-manifest`
   and
   `git merge-tree --write-tree HEAD origin/claude/3IVL9t0P-strike-twice`
   both exit 0. If either has since merged into `origin/main`, rebase and
   re-run instead.

## Enablement

`none needed` — no blocker item, and no `blocked_by` edge.

- **No decision record is owed.** D31 already decides this: its
  `decision` reads "admitting `current` to the control set only when it
  names the same binary as the retry — a mismatch drops it from the set
  rather than refusing, leaving exactly the single pair the gate read
  before." A stampless file names no binary, so this slice implements
  D31 rather than revising it; D31 stays `active` and is not amended
  (nothing under it moved). The asymmetry the slice introduces
  (`same = true` refuses on an absent stamp, `same = false` warns) is a
  rule a doc comment carries in place, which `skills/decide` explicitly
  excludes from records. Numbers checked in case one had been owed:
  `origin/main` carries d01–d32; `d33` is claimed by
  `origin/claude/3IWJ2cHm-metatable-value-type` (#1481) and `d34` by
  `origin/claude/3IVL9t0P-strike-twice` (#1483), both unmerged — the
  next free number is **d35** (verified with
  `git ls-tree --name-only <ref> docs/decisions/` across `origin/main`
  and the 25 most recently updated remote branches).
- **The pinned-checker (cold-build) rule is satisfied.**
  `_perf/skew_test.tl` type-checks every non-test `_perf` source under
  the pinned bootstrap; this change introduces one plain Teal function
  and one boolean expression, uses no new `cosmic.*` or `cosmo.*` API,
  and needs no narrowing the pinned checker lacks. No release or pin
  bump has to stage in front of it.
- **The wrong turns a literal-minded builder could take, and what
  catches each.** (a) Making `identity_refusal` refuse on an absent
  stamp for BOTH values of `same` — caught by
  `test_a_file_without_a_sha_is_not_refused`, which this slice leaves
  unedited, and named in `Non-goals`. (b) Appending the new tests to the
  end of `_perf/gate_test.tl` — caught by Acceptance 6's line-count
  equality and by Acceptance 8's merge-tree check; the reason is spelled
  out in `Change`. (c) Deleting or relaxing one of the five existing
  tests instead of stamping its fixtures — caught by Acceptance 3 and
  named in `Non-goals`; all five keep their expected exit codes, which
  was verified by running them against the prototype. (d) Adding
  `test_x()` self-call lines — named in `Change` step 6 with the
  measurement that shows the neighbour has none.
