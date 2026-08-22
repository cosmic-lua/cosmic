## Goal

**Attach this item under `3I9mIYjY`, sibling of `3IFqha5Y`, and record
`blocked_by 3IFqha5Y` on it.** It is filed unparented only because
`plan` was at 42/12 when `3I9mIYjY` was decomposed and `new --parent`
was refused; the WIP limit is not widened to admit it and `--force` is
not used for flow.

Serves `3I9mIYjY`, under the `cosmic.fuzz` epic `3I1j7yQA`. The cosmic
half: once a released `cosmos` carries `cosmo.cov.budget`, the fuzz
driver stops standing its budget down under the instrumented coverage
stage and uses the collector's own budget instead — so `--make
coverage` runs the fuzz properties with hang protection, which it does
not today.

## Blocked on

`3IFqha5Y` (the `cosmo.cov.budget` C slice in whilp/cosmopolitan) must
land AND a release carrying it must exist, because this slice's first
step is a `3p/cosmos/cosmos_pin.tl` bump. Recorded as a `blocked_by`
edge; do not start before `cosmo.cov.budget` is callable from a pinned
binary.

## Measurement (2026-08-22, main `aaf4af95`)

- `_fuzz/driver.tl` is **390 lines** (110 under the 500-line cap;
  `wc -l _fuzz/driver.tl`). The three pieces this slice touches:
  `BUDGET_MESSAGE` (`:42`), `arm_budget` (`:53`) — which returns false
  whenever `debug.gethook() ~= nil` — and `disarm_budget` (`:64`).
  `run_in_process` (`:149`) calls `arm_budget(budget)` before each
  `pcall(opts.check, input)` and `disarm_budget()` after, per
  iteration.
- `_fuzz/driver_test.tl` is **406 lines** (94 under the cap). Its two
  budget tests (`:245`, `:267`) already bracket themselves with a
  `without_coverage` helper (`:234`) that calls
  `coverage.stop()`/`coverage.start()`, precisely because the budget
  cannot arm while the collector holds the slot. That helper is the
  thing this slice makes unnecessary for the collector case.
- The stand-down is documented in `Options.budget`'s doc comment
  (`_fuzz/driver.tl:83-89`) and in `driver_test.tl:228-233`; both say
  the budget stands down under instrumentation, and both become wrong
  when this lands.
- `3p/cosmos/cosmos_pin.tl` currently pins
  `2026.08.21-07fc94a1c`.

## Change

Bump the pin, then teach `arm_budget`/`disarm_budget` to prefer the
collector's budget.

- `3p/cosmos/cosmos_pin.tl`: bump `version` and the `sha` to the first
  release carrying `cosmo.cov.budget`. Follow AGENTS.md's pin-bump
  procedure: `bin/cosmic --make fetch`, then `bin/cosmic --make build`
  (which regenerates `o/_types/types_gen` from the new
  `definitions.lua`, so `cosmo.cov.budget` becomes a typed call with no
  regen step), then `o/bin/cosmic --make ci`.
- `_fuzz/driver.tl`, `arm_budget`: try the collector first. Resolve
  `cosmo.cov` the way `cosmic/coverage/init.tl:39` does — through
  `package.preload` so a runtime without the binding never executes a
  require — and call `cov.budget(budget)`. When it returns true, the
  budget is armed on the collector's hook: return true, and record
  which mechanism armed it so `disarm_budget` clears the right one.
  When it returns false (no collection running on this thread), fall
  through to today's `debug.gethook() ~= nil` test and
  `debug.sethook` path unchanged.
- `_fuzz/driver.tl`, `disarm_budget`: clear whichever was armed —
  `cov.budget(0)` for the collector's, the existing empty-mask
  `debug.sethook` for the Lua one. Keep it a plain pair of functions;
  a single `local armed_via: string = nil` upvalue beside them is
  enough state, and it stays correct because `run_in_process` arms and
  disarms around one `pcall` at a time.
- `_fuzz/driver.tl`, `BUDGET_MESSAGE`: the collector raises its own
  string, `"cosmo.cov: instruction budget exceeded"`. Recognize BOTH
  that and the existing `"_fuzz.driver: instruction budget exceeded"`
  at the comparison in `run_in_process` (`:163-166`), so a budget
  failure reports `budget=<n> exceeded` whichever hook caught it. Do
  not change the reported message format — `driver_test.tl:261` asserts
  `budget=100000 exceeded` verbatim.
- `_fuzz/driver.tl`, `Options.budget`'s doc comment (`:83-89`): replace
  the stand-down sentences with what is now true — the budget arms on
  the collector's own hook when collection is running, and on the VM
  hook otherwise; a hang inside a single C call is still out of reach
  of both.
- `_fuzz/driver_test.tl`: add
  `test_the_budget_holds_under_the_collector` — the looping property of
  `:245`, run WITHOUT the `without_coverage` bracket and with
  `coverage.start()` held, asserting the run fails with
  `budget=<n> exceeded`. Leave the two existing budget tests and the
  `without_coverage` helper in place: they cover the no-collector path,
  which is still the plain suite's path.

## Non-goals

- **Do not change `cosmo.cov`, `definitions.lua`, or anything in
  whilp/cosmopolitan.** That contract is frozen here and lands as
  `3IFqha5Y`; this slice consumes it.
- No change to the failure message format (`budget=%d exceeded`), to
  `Options`' field names, or to `DEFAULT_BUDGET` / `DEFAULT_TIMEOUT_MS`
  values — `driver_test.tl` and the `*_fuzz_test.tl` properties read
  them.
- Do not remove the wall-clock `timeout_ms` backstop or its doc: a hang
  inside a single C call is still outside every instruction hook's
  reach, which is what that backstop is for.
- No change to `cosmic/coverage/init.tl` — the collector's Lua wrapper
  is not in this slice, and the driver reaches `cosmo.cov` directly the
  way that module already documents.
- No new `cosmic.*` public module or wrapper for `cov.budget`; `_fuzz`
  is internal and reaches the binding directly, as
  `cosmic/coverage/init.tl` does.
- Do not touch `.github/workflows/fuzz.yml`.

## Acceptance

```
bin/cosmic --make fetch
bin/cosmic --make build
o/bin/cosmic --make ci
o/bin/cosmic --make test _fuzz/driver_test.tl
o/bin/cosmic --make coverage _fuzz
```

- `ci: PASS`, quoted in the PR description.
- `_fuzz/driver_test.tl` passes, including the new
  `test_the_budget_holds_under_the_collector`; that test fails against
  `main`'s `_fuzz/driver.tl` on the same bumped pin — show both runs in
  the PR description.
- `wc -l _fuzz/driver.tl` and `wc -l _fuzz/driver_test.tl` both stay
  under 500.
- the diff touches only `3p/cosmos/cosmos_pin.tl`, `_fuzz/driver.tl`,
  and `_fuzz/driver_test.tl`.

## Enablement

blocked on `3IFqha5Y` (recorded in `blocked_by`): the binding it calls
does not exist yet and must ship in a pinned release first. Nothing
else is missing — the three functions to change are named by line, the
`package.preload` resolution pattern has an in-tree precedent at
`cosmic/coverage/init.tl:39`, the test to model on is named by line,
and the pin-bump procedure is AGENTS.md's.
