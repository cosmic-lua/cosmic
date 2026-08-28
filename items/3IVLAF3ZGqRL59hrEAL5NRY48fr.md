## Goal

G6 — the defining paths, ratcheted (parent `3HyRcd9F`). The perf gate is
one of those paths: it refuses to publish a release whose scenarios
regressed, and it separates a real regression from machine variance with
same-binary A/A controls. This slice makes the identity precondition
under those controls real instead of vacuous.

## Problem (re-measured 2026-08-28 at `origin/main` = `3ff022d3`)

`compare.identity_refusal` (`_perf/compare.tl:306-331`) answers two
questions with one function, and returns `nil` — "the pair is sound" —
whenever either file lacks `meta.bin_sha` (`_perf/compare.tl:308-315`).
`_perf/gate.tl:266` then reads that `nil` as proof of sameness:

```teal
local controls = {retry, opts.selfcheck_b}
if identity_refusal(retry, opts.current, true) == nil then
  table.insert(controls, 1, opts.current)
end
```

so a `current` with no stamp is admitted as a SAME-BINARY noise control.
The comment directly above it (`_perf/gate.tl:261-264`) promises the
opposite — "`current` joins the controls only when it names the SAME
binary as the retry" — and so does D31's decision text ("admitting
`current` to the control set only when it names the same binary as the
retry"). A stampless file names no binary at all, so the code does not
implement its own comment or its own record. The same vacuity sits under
the three refusals that assert sameness: `_perf/gate.tl:189` (the
baseline retry), `:248` (the A/A control pair), `:316` (`selfcheck`).
All four call sites re-measured today with
`grep -n 'identity_refusal(' _perf/gate.tl` → `112, 120, 142, 189, 225,
248, 266, 316`; of those, `:142` and `:225` pass `same = false` and are
not this slice's subject.

**The constructed case** (recorded by the refine that opened this item,
against `origin/main` = `6a4d0182`). Driver: `base` stamped `aaaa1111`
at 1000ns; `current` at 2000ns; the injected `measure` writes `retry`
1400ns and `selfcheck_b` 1390ns, both stamped `bbbb2222`. The ONLY
variable is whether `current` carries a stamp:

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

**That evidence still describes today's tree, and this was checked
rather than assumed.** `git diff --stat 6a4d0182 3ff022d3 --
_perf/compare.tl` is EMPTY (the file is byte-identical), and
`git diff 6a4d0182 3ff022d3 -- _perf/gate.tl | grep -E '^@@'` returns
three hunks — `@@ -2,15 +2,25 @@` (module doc), `@@ -182,6 +192,32 @@`
(D34's `base_side` re-key, which the driver does not reach because it
passes no `measure_baseline`) and `@@ -349,16 +385,34 @@` (`main`). The
control-admission region is untouched. The implementer should NOT re-run
the driver; the four line numbers above are the facts to re-check.

**How a stampless file arises: by hand, not from a lane.** `run.tl`
stamps from `fs.read(meta.bin)` where `meta.bin` is
`PERF_BIN or arg[-1]` (`_perf/run.tl:131-147`; re-measured today —
`grep -n 'bin_sha\|PERF_BIN' _perf/run.tl` → `132, 138, 143`).
Re-measured under `o/bin/cosmic` on 2026-08-28: `arg[-1]` is the argv
the caller used (`cosmic /abs/zz.tl` → `/home/user/cosmic/o/bin/cosmic`;
`./o/bin/cosmic zz.tl` → `./o/bin/cosmic`), readable either way from the
cwd the run started in; `--make run` spawns the target with an ABSOLUTE
cosmic path (`_make/runverb.tl`'s `child_argv = {cosmic, target_lua}`);
`bin/cosmic` execs `${ROOT}/o/bin/cosmic` absolute; and the baseline side
— NEW since this item was written — goes through `_perf/baserun.tl`,
whose `argv()` is `{bin, "--modules", modules, ENTRY}`
(`_perf/baserun.tl:125-131`) and which sets no `PERF_BIN`, so the child's
`arg[-1]` is the `--bin` path `release.yml:184` hands it
(`o/perf/prev/cosmic-lua`), readable from the repo root. All four
documented commands and both `release.yml` perf invocations
(`release.yml:139-140`, `:178-184`) therefore stamp. The reachable
triggers are: `PERF_BIN` pointed at an unreadable path (verified:
`PERF_BIN=/no/such/binary` → `readable=false` → no stamp), a results
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
results file into a hard failure (that call site passes `same = false` —
`_perf/run.tl:333-334`, re-measured today), break
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
- control ADMISSION (`_perf/gate.tl:266`): drop, never refuse — which is
  what the existing comment already promises ("a control lost, not a
  refusal ... dropping `current` leaves exactly the one pair the gate
  read before").

## Change

1. `_perf/compare.tl` (357 lines today; `wc -l < _perf/compare.tl` = 357,
   143 lines of headroom under the 500-line cap). Add, immediately above
   the `--- Refuse a pair of results files` doc block that opens
   `identity_refusal`:

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
   b_res: pt.Results): boolean` on the `compare` record IMMEDIATELY
   ABOVE the existing `identity_refusal:` field (`_perf/compare.tl:337`)
   and export it on `M` immediately above `identity_refusal =
   identity_refusal,` (`:349`). `grep -c "same_binary" _perf/compare.tl`
   is 0 today.

2. `_perf/compare.tl`, inside `identity_refusal`'s `if not sa or not sb
   then` branch (`:308-315`): keep the existing stderr line, then, when
   `same` is true, RETURN a refusal string instead of `nil`. Wording:
   name both paths and say that an unidentified pair is not a noise
   floor. When `same` is false, still `return nil`. Extend the function's
   doc comment (the `A file with no bin_sha cannot be checked either
   way` paragraph, `:297-299`) to state the asymmetry: absence cannot
   prove sameness, and is not evidence of difference either.

3. `_perf/gate.tl` (460 lines today; `wc -l < _perf/gate.tl` = 460, 40
   lines of headroom). Add a path-level `same_binary(a: string, b:
   string): boolean` **immediately ABOVE the `--- The identity rule of
   `compare.identity_refusal`, over two paths.` doc block at `:107`** —
   not below the function it accompanies. It loads both files with
   `compare.load_results`, returns `false` when either fails to load,
   else `compare.same_binary(ra, rb)`. **The placement is load-bearing,
   not taste:** PR #1485 (`3IUBNQZZ`, in `check`) inserts its own
   `print_report` helper into the slot directly BELOW the path-level
   `identity_refusal` and directly above `--- Print the gate's verdict`.
   Measured on a prototype carrying this exact Change, at `origin/main`
   = `3ff022d3`: with the helper placed below, `git merge-tree
   --write-tree HEAD refs/pull/1485/head` exits 1 with `CONFLICT
   (content): Merge conflict in _perf/gate.tl`; with the helper placed
   above, it exits 0.

4. `_perf/gate.tl:266`: replace
   `if identity_refusal(retry, opts.current, true) == nil then` with
   `if same_binary(retry, opts.current) then`. Leave the comment at
   `:261-264` as it stands — it now describes the code.

5. `_perf/gate_test.tl` (380 lines today, after D34's split moved 99
   lines out to `_perf/gate_strike_test.tl`; 120 lines of headroom).
   Five existing tests fabricate stampless fixtures and reach a
   `same = true` path, where they would now hit the new refusal or lose
   a control. Stamp their fixtures IN PLACE — add a third argument to
   the existing `write_results` calls, changing no assertion and no
   expected exit code: the `base` file gets `"aaaa1111"`, the `cur` file
   and every file the injected `measure` writes get `"bbbb2222"`. The
   five, at today's line numbers:
   `test_persistent_regression_triaged_as_noise_passes` (`:99`),
   `test_large_regression_survives_unstable_selfcheck_and_fails` (`:131`),
   `test_real_regression_survives_triage_and_fails` (`:154`),
   `test_selfcheck_reports_quiet_and_noisy` (`:188`),
   `test_the_gate_triages_against_every_measured_control` (`:360`).
   `test_selfcheck_reports_quiet_and_noisy` has no base/cur pair — it is
   an A/A run, so BOTH of its files (`out == a and 1000 or 1010` at
   `:193`, and the `1500` at `:201`) get `"bbbb2222"`.
   Exactly two lines cross 90 columns once the argument is added — `:370`
   (79 → 91) and `:372` (83 → 95), both trailing comments inside
   `test_the_gate_triages_against_every_measured_control` — so move those
   two comments onto their own line above. Measured with
   `awk 'NR>=99 && /write_results\(/ {print NR, length($0)+12}'
   _perf/gate_test.tl`: every other stamped line lands at 88 columns or
   less, and `awk 'length>90' _perf/gate_test.tl | wc -l` is 0 today.
   Touch nothing else in this file; in particular leave
   `test_a_file_without_a_sha_is_not_refused` (`:340`) exactly as it is,
   since the `same = false` behaviour it pins does not change — traced:
   its only identity check is `_perf/gate.tl:142`, which passes
   `same = false`, and its 1000-vs-1010 pair returns 0 before any
   `same = true` call site is reached.

   Only three of the five FAIL without the stamp; the other two
   (`large_regression`, `real_regression`) expect exit 1 and would keep
   passing for the wrong reason. Stamp all five anyway — a test that
   passes because the gate refused, rather than because it triaged, is
   not testing what it names.

6. `_perf/gate_strike_test.tl` (214 lines): **no change.** Every fixture
   in it is already stamped — `grep -c 'write_results([a-z_]*, [0-9]*)'`
   and the equivalent for `write_multi` return 0 unstamped calls — so it
   passes unedited. Verified by reading every fixture-writing line in it:
   `:46, :47, :53, :66, :67, :73, :89, :90, :96, :102, :118, :119, :124,
   :129, :146, :147, :151, :155, :171, :172, :176, :180, :196, :197,
   :203, :207` all carry a sha argument.

7. New file `_perf/gate_identity_test.tl` (~95-120 lines), holding the
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
   Define the tests only — write NO `test_x()` self-call lines. This is
   a D29 RUNNER-MODE file, and the two neighbours are the same:
   `grep -c '^test_' _perf/gate_test.tl` = 0 and
   `grep -c '^test_' _perf/gate_strike_test.tl` = 0 today. Do not read
   AGENTS.md's "test files call each test where they define it" as
   binding here; a zero-self-call `_perf` test file is legal and
   self-invoking, and the runner is what calls them (`3IY0HUUk`).
   Corollary, because it costs an hour otherwise: a bare
   `o/bin/cosmic _perf/gate_identity_test.tl` is a SILENT no-op on a
   runner-mode file and exits 0 having run nothing (`3IUKyP4L`). Verify
   only through `--make test`, as Acceptance 2 does.

8. If the coverage ratchet complains, run exactly the regeneration
   command its failure message prints (today that is
   `bin/cosmic --make coverage --baseline`) and commit the result.
   Both files carry floors — `.cosmic-coverage:111` is
   `_perf/compare.tl 105/107` and `:112` is `_perf/gate.tl 164/208` — so
   a regen is likely, not hypothetical. Never lower a floor to
   accommodate an uncovered new branch; cover it instead.

**Capacity, measured, because this file is the tight one.**
`_perf/gate.tl` is 460 today. The prototype of this Change makes it 473.
PR #1485 alone makes it 478. The merge of both — read out of
`git merge-tree --write-tree` and not estimated — is **491 lines, 9
under the 500-line cap.** `_perf/compare.tl` after both is 415. So keep
the new gate.tl helper to the ~13 lines the prototype used, and do not
take the opportunity to expand a neighbouring comment.

**Composition with the one unreviewed PR that touches `_perf/gate.tl`.**
Re-verified 2026-08-28 with `git merge-tree --write-tree` from a scratch
commit carrying this exact Change (helper placed per step 3), at
`origin/main` = `3ff022d3`: against `refs/pull/1485/head` — **rc=0,
clean**. The two blockers this item once carried have both MERGED:
`3IVF3HbV` / #1480 as `3ff022d3`, and `3IVL9t0P` / #1483 as `b0aeb1dd`,
so their branches are no longer a composition question. No blocker edge
is needed in either direction, but see `## Non-goals` for the
serialization note on #1485.

## Non-goals

- **Do not change the `same = false` behaviour.** A pair where one side
  has no stamp still warns and still compares. `run.tl --compare` over an
  archived pre-#1432 results file must keep working
  (`_perf/run.tl:333-334` passes `same = false`), and
  `test_a_file_without_a_sha_is_not_refused` must keep passing unedited.
- **Do not make `run.tl` refuse to write a stampless results file**, and
  do not change how `meta.bin` / `meta.bin_sha` are derived
  (`_perf/run.tl:118-147`). That is a separate question and belongs to
  `3IVEEDO8`.
- **Do not touch `TRIAGE_K`, `DEFAULT_THRESHOLD_PCT`, `diff`, `triage`,
  `triage_many`, or `loudest_control`.** D31 froze `compare.triage`'s
  signature and fixed `TRIAGE_K = 2` and the 10% bar
  (`_perf/compare.tl:19` and `:27` today); this slice changes WHICH runs
  may be controls, never how much credit a control buys.
- **Do not weaken any scenario, functional check, or existing
  assertion.** Every expected exit code in `_perf/gate_test.tl` stays as
  it is; the only edit there is adding a stamp argument and moving two
  trailing comments.
- **Do not touch `_perf/run.tl`, `_perf/baseline.tl`, `_perf/baserun.tl`,
  `_perf/harness.tl`, `_perf/stats.tl`, `_perf/peers/**`,
  `_perf/bench/**`, `.github/workflows/release.yml`, or
  `skills/optimize/**`.** No lane's commands change. `_perf/peers/**`
  carries its own `cosmic_bin_sha` field and never reaches
  `compare.identity_refusal` (`grep -rln 'identity_refusal' _perf/`
  returns only `compare.tl`, `gate.tl`, `run.tl`, `gate_test.tl`,
  `gate_strike_test.tl`) — it is a different report, out of scope.
- **Do not touch `_perf/gate_strike_test.tl`** (step 6: already stamped)
  **and do not restructure `_perf/gate_test.tl`** beyond the five
  stamped fixtures and the two moved comments.
- **Do not commit anything under `o/perf/`,** and do not run the real
  `_perf` harness for this slice: nothing here is a timing claim, every
  test injects `measure`, and `3IU0GxoA` established that absolute
  readings are not comparable across sessions anyway.

**What this does NOT license.** This slice makes an existing precondition
non-vacuous. It is not permission to touch the arithmetic that
precondition guards, and specifically not any of the following, none of
which it needs:

- **No threshold, floor or bar is created, widened, or moved.** The only
  committed number of that kind is `DEFAULT_THRESHOLD_PCT = 10.0`
  (`_perf/compare.tl:19`), with `TRIAGE_K = 2.0` (`:27`), and no
  scenario module carries a per-scenario floor:
  `git grep -nE 'noise_floor|threshold_pct *=' -- _perf/bench` returns
  no matches on `origin/main` today. `3ISlY5Xl` held a release at
  `21.0 > max(10.0, 2 × 4.8)` — that arithmetic is what makes the gate
  honest, and a widened floor retires it. If a test in this slice needs
  a different bar to make its point, change the FIXTURE numbers, never
  the committed constant.
- **No row's classification rule moves.** The slice changes which runs
  may enter the `controls` list, not how `triage_many` weighs the list.
- **The `noise` verdict is not being made cheaper to earn.** Every one
  of the four new tests asserts `code == 1` — the direction of this
  change is strictly toward failing, never toward passing.
- **Nothing here licenses re-running or re-litigating a perf number.**
  No measurement in this spec is a timing measurement.

**Serialization with PR #1485 (`3IUBNQZZ`, `check`).** The two are
merge-clean as specified (measured above), so neither blocks the other
and no `blocked_by` edge is warranted. But both touch
`_perf/compare.tl`'s `record compare` / `M` block and both insert a
helper into `_perf/gate.tl`, so whichever lands second must re-run
Acceptance 8 after rebasing, and must re-check the 500-line cap on
`_perf/gate.tl` (491 combined — 9 lines of headroom).

**Relation to `3IWx3I4Z` (`backlog`, unrefined).** It wants a SECOND
control group in `triage_many` so the baseline pair earns noise credit,
and its own spec says it needs `loudest_control` and `triage_many` —
which this slice's `Non-goals` forbid touching. Its edit region in
`_perf/gate.tl` is the same `local controls = {retry, opts.selfcheck_b}`
block this slice edits at `:265-268`. This slice is the smaller and
earlier change and should land first; `3IWx3I4Z` rebases onto
`same_binary` when it is refined. No edge is filed: `3IWx3I4Z` is not
blocked by this (it could be written either way) and this is not blocked
by it.

**Relation to `3IVEEDO8` (`plan`, blocked by `3IUBNQZZ`).** Adjacent
subject, disjoint code. It prints `meta.timestamp` in a report header and
its Change lands in `_perf/perf_types.tl`, `_perf/run.tl`'s
`RESULTS_SPEC`, and the header `3IUBNQZZ` introduces. This slice touches
none of those and reads `meta.bin_sha` only. The one shared fact is that
both are about `meta` identity, which is a reason to keep the Non-goal
above pointing at `3IVEEDO8` — not a reason for an edge.

## Acceptance

Run from the repo root. Every command is literally runnable as written
and writes into no committed file.

1. `bin/cosmic --make ci` ends `ci: PASS`.
2. `bin/cosmic --make test _perf/gate_identity_test.tl` passes, running
   all four new tests. (Do NOT substitute a bare
   `o/bin/cosmic _perf/gate_identity_test.tl` — on a runner-mode file
   that is a silent no-op exiting 0, `3IUKyP4L`.)
3. `bin/cosmic --make test _perf/gate_test.tl _perf/gate_strike_test.tl
   _perf/compare_test.tl` passes with no assertion changed.
4. The new tests are runner mode, matching their neighbours:
   `grep -c '^test_' _perf/gate_identity_test.tl` is 0,
   `grep -c '^test_' _perf/gate_test.tl` is 0, and
   `grep -c '^test_' _perf/gate_strike_test.tl` is 0.
5. The constructed case fails WITHOUT the fix. This runs the SAME new
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
6. The new predicate exists and the double-negative admission is gone:
   - `grep -c "same_binary" _perf/compare.tl` is at least 3 (definition,
     record field, export) — it is 0 on `origin/main`.
   - `grep -c "identity_refusal(retry, opts.current, true)" _perf/gate.tl`
     is 0 — it is 1 on `origin/main`.
   - `grep -c "same_binary(retry, opts.current)" _perf/gate.tl` is 1.
7. The pinned-checker (cold-build) guard passes, which is the wall that
   bounced this item once and is the one check worth running early:
   `bin/cosmic --make test _perf/skew_test.tl` passes. Equivalently and
   faster, once `o/bootstrap/cosmic` exists, the sweep it performs:

   ```sh
   mkdir -p /tmp/skew-inc && ln -sfn "$PWD/_perf" /tmp/skew-inc/_perf &&
     COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types \
       --include-dir /tmp/skew-inc _perf/compare.tl _perf/gate.tl
   ```

   must print `Type check passed:` for both and exit 0.
8. File-length and style bounds:
   - `wc -l < _perf/gate_identity_test.tl` is at most 120.
   - `wc -l < _perf/gate_test.tl` is at most 382 (380 on `origin/main`
     today; the two moved comments in step 5 are the only additions, and
     they add exactly 2 lines).
   - `wc -l < _perf/gate.tl` is at most 480 (460 on `origin/main`; the
     prototype measured 473).
   - `wc -l < _perf/compare.tl` is at most 375 (357 on `origin/main`;
     the prototype measured 373).
   - `awk 'length>90' _perf/gate_test.tl | wc -l` is 0.
   - `awk 'length>90' _perf/gate_identity_test.tl | wc -l` is 0.
   - `awk 'length>90' _perf/gate.tl | wc -l` and
     `awk 'length>90' _perf/compare.tl | wc -l` are each no larger than
     on `origin/main`
     (`git show origin/main:_perf/gate.tl | awk 'length>90' | wc -l` and
     the same for `compare.tl` give today's values).
9. No threshold ends larger than it starts:
   - `git diff origin/main -- _perf/compare.tl | grep -E
     'DEFAULT_THRESHOLD_PCT|TRIAGE_K'` is empty.
   - `git grep -nE 'noise_floor|threshold_pct *=' -- _perf/bench` is
     empty (it is empty on `origin/main` today).
   - `git diff origin/main -- _perf/compare.tl` shows no change inside
     `diff`, `triage`, `triage_many`, `loudest_control`, `format_delta`
     or `format` — only the new `same_binary`, the two-line branch and
     doc edit inside `identity_refusal`, and the record/export block.
10. The diff touches exactly four paths:
    `git diff origin/main...HEAD --name-only` lists exactly
    `_perf/compare.tl`, `_perf/gate.tl`, `_perf/gate_identity_test.tl`,
    `_perf/gate_test.tl` — plus `.cosmic-coverage` only if step 8 of
    `Change` was needed. `_perf/gate_strike_test.tl` must NOT appear.
11. Composition still holds at merge time:
    `git merge-tree --write-tree HEAD refs/pull/1485/head` exits 0
    (fetch it first with
    `git fetch origin refs/pull/1485/head:refs/pr1485` and use
    `refs/pr1485`). If #1485 has since merged into `origin/main`, rebase
    onto `origin/main` and re-run Acceptance 1 and 8 instead — the
    combined `_perf/gate.tl` measures 491 lines, so the 500-line cap is
    the thing to re-check.

## Enablement

`none needed` — no blocker item, and no `blocked_by` edge. This replaces
the WRONG `none needed` that bounced this item on 2026-08-28; the
difference is that the claim is now measured rather than reasoned, and
the blocker it missed has merged.

- **The pinned-checker (cold-build) wall is retired, measured today.**
  The bounce found that `_perf/gate.tl` reaching `_perf/compare.tl`'s
  new `same_binary` key failed `_perf/skew_test.tl`, because the pinned
  bootstrap's embedded `/zip/.tl/_perf/compare.tl` shadowed the tree's.
  `3IVF3HbV` / PR #1480 merged as `3ff022d3` and rewrote
  `_perf/skew_test.tl` to pass `--include-dir` scoped to a `_perf`-only
  directory (`_perf/skew_test.tl:59-77, :88-89`), so `_perf.*` resolves
  from the tree while `cosmic.*` still comes from the pin. Verified
  against a prototype of this exact Change on 2026-08-28, with
  `/home/user/cosmic/o/bootstrap/cosmic`:

  ```text
  $ COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types \
      --include-dir /tmp/skew-inc <all 31 non-test _perf sources>
  Type check passed: ...            (31 files, rc=0)

  $ COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types \
      _perf/compare.tl _perf/gate.tl          # the OLD, unscoped form
  _perf/gate.tl:117:18: error: invalid key 'same_binary' in record
    'compare' of type record compare
  ```

  The exact bounce failure reproduces without the scoped include dir and
  is gone with it. That is what makes the cross-module shape in `Change`
  step 1 legal in ONE PR, and it is why option 3 of the bounce ("keep
  `same_binary` inside `_perf/gate.tl` alone") is NOT taken: the reason
  for it no longer exists, and the predicate belongs beside
  `identity_refusal`, whose double negative it replaces.
  Acceptance 7 is this check, so a regression in the guard lands on the
  PR rather than in the release lane.
- **No decision record is owed.** D31 already decides this: its
  `decision` reads "admitting `current` to the control set only when it
  names the same binary as the retry — a mismatch drops it from the set
  rather than refusing, leaving exactly the single pair the gate read
  before." A stampless file names no binary, so this slice implements
  D31 rather than revising it; D31 stays `active` and is not amended
  (nothing under it moved). The asymmetry the slice introduces
  (`same = true` refuses on an absent stamp, `same = false` warns) is a
  rule a doc comment carries in place, which `skills/decide` explicitly
  excludes from records. If the implementer disagrees and writes one,
  the next free number must be re-derived at that moment, not taken from
  this spec — D33 and D34 have landed since it was last checked.
- **The wrong turns a literal-minded builder could take, and what
  catches each.**
  (a) Making `identity_refusal` refuse on an absent stamp for BOTH
  values of `same` — caught by `test_a_file_without_a_sha_is_not_refused`,
  which this slice leaves unedited, and named in `Non-goals`.
  (b) Putting the new `_perf/gate.tl` helper BELOW the path-level
  `identity_refusal` — caught by Acceptance 11's merge-tree check
  against #1485; the measured conflict and the correct slot are in
  `Change` step 3.
  (c) Deleting or relaxing one of the five existing tests instead of
  stamping its fixtures — caught by Acceptance 3 and named in
  `Non-goals`; all five keep their expected exit codes.
  (d) Adding `test_x()` self-call lines because AGENTS.md says test
  files call each test where they define it — caught by Acceptance 4,
  and `Change` step 7 states the runner-mode exception with the
  measurement showing both neighbours have zero.
  (e) Verifying the new tests with a bare
  `o/bin/cosmic _perf/gate_identity_test.tl`, which exits 0 having run
  nothing — named in `Change` step 7 and forced by Acceptance 2's
  `--make test` form.
  (f) Widening `DEFAULT_THRESHOLD_PCT` or adding a per-scenario floor to
  make a fixture behave — caught by Acceptance 9 and by the
  "What this does NOT license" paragraph in `Non-goals`.
  (g) Blowing the 500-line cap on `_perf/gate.tl` after #1485 lands —
  caught by Acceptance 8's 480 bound and Acceptance 11's rebase clause,
  with the 491-line combined measurement in `Change`.
- **No enablement item is owed.** Every wrong turn above already has a
  gate or an Acceptance command; none of them needs new tooling, and the
  one countermeasure that WOULD have been core work — making a
  cross-module `_perf` key type-check under the pin — has already landed
  as `3IVF3HbV`.

## History

- **2026-08-27** — refined and moved to `ready`; the constructed case in
  `## Problem` was measured then, against `origin/main` = `6a4d0182`.
- **2026-08-28** — bounced from `do` with the Change implemented and
  correct (branch `claude/3IVLAF3Z-stampless-identity` at `b346ca66`, no
  PR opened), because `## Enablement`'s `none needed` missed the
  `_perf/skew_test.tl` cross-module wall. That branch is now stale: it
  predates `3ff022d3` and `b0aeb1dd`, and its `_perf/gate.tl` helper is
  in the slot `Change` step 3 now forbids. Re-implement from this spec
  rather than resurrecting it.
- **2026-08-28, this refine** — the wall is measured retired
  (`## Enablement`), every source fact is re-measured at `origin/main` =
  `3ff022d3`, the `## Acceptance` line-count contradiction the bounce
  flagged is resolved (bounds, not equalities), the helper's slot in
  `_perf/gate.tl` is fixed by a measured merge conflict, the
  `_perf/gate_strike_test.tl` no-change finding is recorded, and the
  wall paragraph plus the `3IWx3I4Z` / `3IVEEDO8` / `3IUBNQZZ` relations
  are written in.
