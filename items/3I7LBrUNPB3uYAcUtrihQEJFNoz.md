## Goal

G2, requirements R1 and R3: `apply` never returns success while
enforcing less than requested without saying, per section, what was
degraded or skipped and why — and the options surface cannot construct
a kernel EINVAL. Fixes the epic's defect 4 (a 5.13–6.1 kernel strips
TRUNCATE/REFER and `apply` still answers as if enforcement were full)
and its footgun (a truthy `{fs = false, sys = false}` from `best_effort`
when NOTHING was enforced, so `if sandbox.apply(p) then` lies).

## Change

Public-surface rework of `cosmic.sandbox` (`init.tl`, 360 lines) and
`cosmic.sandbox.landlock` (295 lines), with the semantics recorded as a
decision record (R8). Decisions settled here:

1. **`landlock.restrict` returns what it enforced.** Signature moves
   from `boolean, string` to `Enforcement | nil, string` where
   `record Enforcement` carries `abi: integer`, `handled: integer` (the
   mask actually handled), `stripped: integer` (rights requested but
   ABI-masked away — `abi_mask` at line 137 is where they drop). In-tree
   callers, measured: `init.tl`'s `apply_fs` (line 169) and the module's
   own tests — both updated here.
2. **`apply` returns a per-section report.** `SandboxModule.apply`
   becomes `function(opts: Options): Report | nil, string`;
   `record Report` has `fs: Section` and `sys: Section` (nil when the
   section was not requested); `record Section` has
   `state: string` — `"full"` | `"degraded"` | `"skipped"` —
   `mechanism: string` ("landlock" | "unveil" | "pledge"),
   `abi: integer` (0 where meaningless), `missing: string` (human
   rendering of what was stripped/skipped, "" when full). `"degraded"`
   is landlock reporting `stripped ~= 0`; `"skipped"` is `best_effort`
   passing an unenforceable section.
3. **The footgun dies by contract.** When every requested section ends
   `"skipped"`, `apply` returns
   `nil, "sandbox: nothing enforced (…)"` even under `best_effort` —
   the natural `if sandbox.apply(p) then` is then correct. Partial
   enforcement returns the Report.
4. **`strict`.** `Options.strict: boolean` — any section that would end
   `"degraded"` or `"skipped"` is instead a refusal naming the section
   and the gap. `validate` refuses `strict` and `best_effort` together.
5. **`handled` leaves the facade (R3).** Delete `Options.handled` and
   `plan.for_landlock`'s `handled?` parameter — measured 2026-08-19:
   zero in-tree consumers outside `cosmic/sandbox/` (grep over `*.tl`;
   every hit elsewhere is unrelated prose). `landlock.RestrictOptions.
   handled` STAYS — it is the mechanism-level door and is pinned by
   `test_narrowed_handled_intersects_rule_access`.
6. **`availability()` says what, not just whether.** `Availability`'s
   `fs`/`sys` become small records (`available: boolean`,
   `mechanism: string`, `abi: integer`) instead of two booleans.
   `is_available()` keeps its boolean contract.
7. **R8: the decision record.** Via the `decide` skill: a new record on
   sandbox enforcement-report semantics — degraded is not refused,
   `strict` is how degraded becomes refusal, nothing-enforced is an
   error — citing D7 where it touches the fence's posture. Ships in the
   same PR.

## Non-goals

- no new enforcement capability: `net` is the R7 slice, gated on the
  cosmopolitan pin; this slice only makes the report able to carry it.
- no change to `landlock.RestrictOptions`, the WRITE/READ masks, or any
  denial — weakening a denial to improve a report is the exact failure
  this epic forbids.
- no changes to `cosmic.quicksand` (its `probe_landlock` already
  delegates; PR #1278).

## Acceptance

- `bin/cosmic --make test cosmic/sandbox/init_test.tl cosmic/sandbox/landlock_test.tl`
  ends `test: PASS (2 files)`, including new pins: degraded reported on
  a stripped mask (unit-level against `abi_mask`), all-skipped returns
  nil, strict refuses a skip, strict+best_effort refused by validate.
- `git grep -n "handled" -- cosmic/sandbox/init.tl cosmic/sandbox/plan.tl`
  shows no Options/for_landlock parameter remaining.
- a new file exists under `docs/decisions/` and
  `bin/cosmic --make ci` ends `ci: PASS` — the decisions-index derive
  test gates the new record's grammar and status.

## Enablement

none needed — the shapes above close every open decision the epic
assigned this slice (report grammar, footgun contract, strict
interaction, the `handled` drop, record-vs-amend); consumers of the old
return shape are enumerated from measurement.
