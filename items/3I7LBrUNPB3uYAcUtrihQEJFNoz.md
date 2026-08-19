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

## Bounced 2026-08-19: the measurement missed real consumers outside cosmic/sandbox/

Before writing any code, `grep -rn "sandbox\.\(apply\|availability\)" --include="*.tl"`
found two call sites this spec's Enablement claim ("consumers of the old
return shape are enumerated from measurement") does not cover and Non-goals
does not exempt (Non-goals only exempts `cosmic.quicksand`, whose two
`sandbox.apply`/`sandbox.validate` calls in `box/run.tl`/`box/init.tl` are
genuinely unaffected — pure truthy checks, no field access, no type name):

1. **`_cli/driver.tl:136-153`, `fence()`** — calls
   `sandbox.apply({fs = fs_policy, best_effort = true})` with `fs` as the
   ONLY requested section, specifically so a host with no landlock at all
   still returns success (a falsy `.fs`), logs a stderr warning only when
   `COSMIC_FENCE` is explicitly set, and lets the recipe **run unfenced by
   design** — the comment at line 116-121 states this is deliberate. Change
   item 3 ("the footgun dies by contract": every requested section ending
   `"skipped"` makes `apply` return `nil, "sandbox: nothing enforced (…)"`,
   even under `best_effort`) directly collides with this: fs-only +
   best_effort on an unenforceable host is now the ALL-skipped case, so
   `apply` would return an error where `fence()` currently expects and
   requires a soft, non-fatal `{fs = false}`-shaped success. As written,
   this slice turns "runs unfenced with a warning" into "dispatch fails
   outright" on every host without Landlock — a real behavior change to
   the build driver that neither the Change nor the Non-goals section
   authorizes or even mentions. This is a genuine design call (does
   `fence()` need its own carve-out? does the footgun contract only bind
   when more than one section was requested? does `fence()` inspect the
   error string and treat "nothing enforced" specially?) and not mine to
   invent mid-implementation.
2. **`_cli/driver.tl:140`**, `if enforced is sandbox.Availability then` —
   `apply`'s return type is changing from `Availability` to `Report`
   (item 2), so this `is` check needs to become `sandbox.Report` merely to
   compile; mechanical, but still an unlisted touch site.
3. **`_cli/fence_test.tl:61,110,208`** — all three read
   `sandbox.availability().fs` as a plain boolean (`if not
   sandbox.availability().fs then check.enforce_skip(...)`). Item 6 turns
   `Availability.fs` into a `MechanismInfo` record (`available`,
   `mechanism`, `abi`), which is always a non-nil table — so these checks
   silently stop skipping on hosts without Landlock instead of failing
   loudly, a correctness bug the "measured" claim missed. Needs
   `.fs.available` at all three sites — mechanical once (1) is decided,
   listed here so it is not rediscovered as a second surprise.

Returned to `plan` for a decision on (1) — the fence's intentional
"unenforceable host runs unfenced" tolerance — before the Change section
can be implemented as written; (2) and (3) are mechanical follow-through
once (1) is settled and can be folded into the same re-refined spec.
