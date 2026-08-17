Imported from whilp/cosmic#1179.

## Goal

G1 — the eval instrument, via epic #1126. Second of two slices split at the
run-dir seam: given a staged run directory in which an operator has already run
the agents, produce `results.json` in the accepted #1135 §4 record format and a
PASS/FAIL verdict, with `silent_bugs` scored by committed per-task functional
checks — never by the agent's claims.

Blocked by: #1147

## Change

Input contract: the run dir #1147 pins (`meta.json`, `probe.txt`, seven
`<id>/` workspaces with `cosmic`, `prompt.txt`, `final.txt`, `err.txt`, agent
work products).

**`_eval/eval_types.tl`** (extend) — result records mirroring #1135 §4 field for
field: `ResultMeta` (the staged ten fields plus `probe_output: string`,
`leaked: boolean` — true iff `probe.txt` contains anything but the READY/NONE
pair), `Row` (`task`, `status` of completed|incomplete|error, `silent_bugs`
integer from the check, `checker_errors`, `cycles`, `attempts_first_build`,
`attempts_green_ci`, `gate_adopted`, `denials`, `denial_recovery_steps`,
`self_report_clean`, `journal_path`, `friction` list), `EvalResults` (`meta`,
`rows`, `verdict`).

Settled positions (were open in the #1135 record):
- `cycles` and `checker_errors` are journal-derived and NULLABLE in v1 — the
  retained artifacts are NOTES.md/final.txt only; making them mechanical
  (transcript retention in the launch command) is a named follow-up child, not
  absorbed here. Null is recorded, never guessed.
- `gate_adopted` is journal-derived and nullable, same rule.
- A check returns `(count, findings)` — a findings list whose length is the
  count; an unbuilt artifact makes the row `incomplete`, which is NOT a silent
  bug.
- **Verdict**: `"PASS"` iff every proven task's row is `completed` AND
  `sum(silent_bugs) == 0` over proven tasks. An incomplete or errored proven
  task FAILS the gate — an unrun suite is not a clean window. A `new` task's
  bugs are recorded, never gate (first run establishes its baseline). The
  verdict line names the failing task ids: `eval: FAIL (<id>, <id>)`.
- `contained-task` is staged and scored everywhere. **`denials` and
  `denial_recovery_steps` are null on EVERY platform in v1** (amended — see
  Amendments): the quantity G2 wants is denials the AGENT hit while working,
  which needs the transcript v1 does not retain. The denial the check itself
  provokes is the scorer's own and is a different quantity; deriving the field
  from it would record a fabricated number. `meta.os` records the platform.
- `leaked = true` does not abort scoring; it is recorded in meta and the
  operator judges the run's validity (the skill's rule stays prose).

**`_eval/checks/<id>.tl`** — seven checks (~60–120 lines each), one per task:
`check(workspace: string): integer, {string}` implementing exactly the brief's
`Acceptance facts` as pinned in #1147's "Brief content" section (transcribed
into `_eval/tasks/<id>.md` by that slice) against the produced artifact — run
the built `o/bin/<name>` on the pinned fixture inputs and compare exact
outputs/exit codes; never read NOTES.md. The `ci: PASS` and file-presence
facts are workspace checks; the S-trap facts (json-cli's zero-count record and
single-line summary, sqlite-indexer's doubled-path refusal and dupes line,
child-tcp's 10-run repetition and no-orphan check, text-report's two boundary
buckets, contained-task's enforced-denial absence check) are each one
assertion in the corresponding check module.

**child-tcp's serve-mode fact is NOT separately implemented** (amended — see
Amendments). Orchestrator mode *is* the serve path — the artifact with no args
spawns its own `serve` child, reads `PORT=<n>`, connects and round-trips — so
the ten-run repeated-invocation assertion already exercises bind, readiness
announcement, echo and exit against real agent code. A scorer-side TCP client
would cover a fixture's fake server instead.

**Scoring must not depend on, or damage, the caller's cwd** (amended). The run
dir is resolved to an absolute path before any check runs — `cosmic.child`
applies `cwd` in the child before exec, so a relative workspace joined into
argv[0] resolves twice and every check fails ENOENT. A scoring run also never
writes into its input: `results.json` and any fixture inputs a check materializes
go somewhere the committed tree does not see.

**`results.json` gets an explicit address** (amended). `_eval/score.tl` accepts
an `--out PATH` option naming where `results.json` is written; with no `--out` it
writes to its default location and prints that absolute path on the line
immediately before the verdict line. The instrument's output record is what the
follow-up history and comparison slices consume, so a path only the scorer's own
internals can derive is not an address. It is also what lets the staging copy be
removed when scoring finishes: `results.json` living inside that copy is the only
reason the copy has to survive the run.

**`_eval/journal.tl`** (~150 lines) — best-effort parser over agent prose:
NOTES.md section (f) → `self_report_clean`; section (b) → `friction` verbatim;
final.txt's five-line reply → `attempts_*` and built/tested. Unfound fields are
null, never guessed.

**`_eval/score.tl`** (~250 lines) — `--make run`-able: read+validate
`meta.json`; fold `probe.txt`; per manifest task run the check and parse the
journal into a Row (missing workspace → `status = "error"`); compute the verdict
per the rule above; write `results.json`; end `eval: PASS` or
`eval: FAIL (<failing task ids>)` with matching exit code.

**Tests + fixtures** — `_eval/score_test.tl`, `_eval/journal_test.tl`,
`_eval/checks/checks_test.tl`, over committed `_eval/testdata/` fixture run dirs
(no real agent run, no binaries): `run_pass/` (clean probe, zero bugs),
`run_fail/` (one proven task seeded with an artifact defect its check catches),
`run_partial/` (missing workspace + unparseable final.txt → error/null paths,
and a proven-incomplete run proving the verdict FAILs). Assert `results.json`
decodes into `EvalResults` with every §4 field present, verdict lines exact,
exit codes correct.

**Every fixture run dir satisfies every assertion it is not deliberately
seeded against** (amended). A marker a check looks for is added to ALL three run
dirs, not only `run_pass` — otherwise `run_fail` and `run_partial` record
defects nobody intended, invisible only for as long as the task stays `new`.
Pin it: `run_fail`'s rows other than the seeded one assert `silent_bugs == 0`.

At least one test scores a fixture through a **relative** run-dir path; the
suite's own `TEST_TMPDIR` paths are always absolute and cannot reach that shape.

## Non-goals

No agent launching; no changes to stage, the manifest, the briefs, or
`skills/agent-eval/`. No history format, retention, cadence, comparison gate, or
peers. No transcript capture — `cycles`/`checker_errors` stay nullable; the
mechanical version is a follow-up child on the epic. No scorer-side TCP client
for child-tcp. No derivation of `denials` from the scorer's own provoked denial.

## Acceptance

Every command below is run **verbatim from the repo root** and must be safe to
run literally — after the run, `git status --porcelain _eval/testdata/` reports
no modification.

- `bin/cosmic --make test _eval/score_test.tl _eval/journal_test.tl _eval/checks/checks_test.tl`
  ends `test: PASS`.
- `bin/cosmic --make run _eval/score.tl _eval/testdata/run_pass` ends
  `eval: PASS`, exit 0 — note the RELATIVE path, which is the shape the
  implementation must handle and the suite cannot reach.
- `bin/cosmic --make run _eval/score.tl _eval/testdata/run_fail` ends
  `eval: FAIL (<task-id>)`, non-zero, naming exactly the seeded task and no
  other, with that row's `silent_bugs ≥ 1` sourced from the check.
- `bin/cosmic --make run _eval/score.tl _eval/testdata/run_partial` still
  writes a complete `results.json` and FAILs on the incomplete proven task.
- `bin/cosmic --make ci` ends `ci: PASS`.

Quote each command's real verdict line in the PR **body**, and re-quote them
whenever a change moves the output grammar.

## Enablement

Blocked by: #1147 — the run-dir layout and the briefs' acceptance facts are this
slice's input spec. Beyond that none needed: checks run artifacts via
`cosmic.child`, journals parse with `cosmic.string`/`cosmic.re`, records encode
with `cosmic.json`.

The acceptance shape above is itself a countermeasure filed as #1237 — an
acceptance command must be safe and meaningful to run literally, which this
issue's original acceptance was not.

## Amendments

Recorded so the next reader does not re-derive rulings already made, and so the
code stops contradicting the issue text.

1. **child-tcp's serve-mode fact is dropped, deliberately.** Ruled at the
   2026-08-17 review of PR #1209. The brief's fact 2 is not independently
   observable in the instrument's real setting; the ten-run assertion already
   covers the serve path end to end against real agent code. The original
   Change section read as if a separate assertion were required.
2. **`denials`/`denial_recovery_steps` are null on every platform**, not "null
   on a non-enforcing platform" as originally written. Same ruling. The
   original wording conditioned nullity on the platform, which made the
   implementation's unconditional null look like a divergence when it is the
   correct behaviour.
3. **The acceptance is respecified** to be safe and meaningful run literally,
   and to name the relative-path shape explicitly, after the original
   acceptance was measured to write ten stray files into the committed tree
   and to name the one input shape no test covered. Ready-bar gap filed as
   #1237.
4. **Fixture symmetry is stated** after round-3's added assertions landed in
   `run_pass` only, leaving `run_fail` and `run_partial` recording unintended
   defects.
5. **`results.json` gets an explicit address**, ruled at the 2026-08-17 round-4
   review of PR #1209. The original body required only that results.json go
   "somewhere the committed tree does not see", which the implementation
   satisfied exactly — by writing it inside the staging copy at a path nothing
   prints, so the instrument's own output record had no address, and the staging
   copy could not be cleaned up because the record lived in it. The `--out PATH`
   option plus the printed default path is the specification gap closed; it was
   the issue's omission, not an implementation divergence.


---
_Generated by [Claude Code](https://claude.ai/code)_