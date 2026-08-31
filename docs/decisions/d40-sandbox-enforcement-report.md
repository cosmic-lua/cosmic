# D40 — sandbox.apply reports full/degraded/skipped per section, and refuses when nothing enforced

- **date:** 2026-08
- **status:** active
- **context:** `cosmic.sandbox.apply` returned a bare `Availability`
  record (`fs: boolean, sys: boolean`) on success. That boolean could
  not tell "enforced exactly as requested" from "landlock enforced,
  but this kernel's ABI stripped rights the caller asked for" — on a
  Linux 5.13–6.1 kernel (ABI 1 or 2), a `best_effort` restrict silently
  drops `TRUNCATE`/`REFER` (`cosmic/sandbox/landlock.tl`'s `abi_mask`
  function) and `apply` still reported `fs = true`, the same value it
  reports on a fully-capable kernel. `_cli/driver.tl`'s `fence()` read
  exactly that boolean, so a stripped-ABI host ran every recipe
  believing it had full enforcement.
  The same boolean was also truthy on a `best_effort` apply that
  enforced NOTHING at all (every requested section unenforceable): `if
  sandbox.apply(p) then` read as success with zero containment in
  place — a footgun for every one-section `best_effort` caller, the
  more common shape of the two.
- **decision:**
  - `landlock.restrict` returns `Enforcement | nil, string` instead of
    `boolean, string`: `abi` (the kernel's ABI), `handled` (the mask it
    actually controls), `stripped` (rights requested but ABI-masked
    away). `landlock.RestrictOptions.handled` stays — it is the
    mechanism-level door, still needed by a direct caller narrowing
    what one ruleset controls.
  - `sandbox.apply` returns `Report | nil, string`: one `Section` per
    requested section (`fs`, `sys`), each carrying `state` — `"full"`,
    `"degraded"` (landlock enforced, but this kernel's ABI stripped
    something), or `"skipped"` (`best_effort` passed an unenforceable
    section) — plus `mechanism`, `abi`, and a human `missing` string.
    The old `Availability` (booleans) is deleted outright as `apply`'s
    return type; `availability()` keeps the name but its `fs`/`sys`
    become small records (`available`, `mechanism`, `abi`) instead of
    bare booleans, for the same reason: `true` could not say which
    mechanism or ABI backed the answer.
  - When every requested section ends up `"skipped"`, `apply` refuses
    (`nil, "sandbox: nothing enforced (...)"`) even under
    `best_effort` — closing the footgun, so the natural `if
    sandbox.apply(p) then` is correct again. `Options.allow_unenforced`
    (default false) is the one named opt-in that tolerates an
    all-skipped result instead of refusing, returning the Report (every
    section `"skipped"`) — for a caller that already documents running
    with zero enforcement on such a host and wants the detail, not a
    hard stop.
  - `Options.strict` (default false) turns any section that would end
    `"degraded"` or `"skipped"` into a refusal naming the section and
    the gap, instead of reporting it. `validate` rejects `strict` with
    `best_effort` (contradictory: strict already refuses any gap, so
    best_effort's skip never triggers), `strict` with
    `allow_unenforced` (tolerating an all-skipped result is meaningless
    once strict already refuses any single skipped section), and
    `allow_unenforced` without `best_effort` (a section is only ever
    `"skipped"` because `best_effort` passed it, so `allow_unenforced`
    alone has nothing to tolerate) — each a kernel-EINVAL-shaped
    self-contradiction in the options rather than a real host state.
  - `Options.handled` and `plan.for_landlock`'s `handled?` parameter are
    deleted (R3): zero in-tree consumers outside `cosmic/sandbox/`
    used the facade-level knob: the plan always requests
    `landlock.ALL`, and per-ruleset narrowing stays a mechanism-level
    concern (`landlock.RestrictOptions.handled`).
  - `_cli/driver.tl`'s `fence()` is the one caller that needs the
    all-skipped case to still succeed — its own doc already states a
    host that cannot enforce at all runs the recipe unfenced by
    design. It passes `allow_unenforced = true` and checks
    `enforced.fs.state ~= "full"` (not `== "skipped"`) before its
    `COSMIC_FENCE`-gated warning: the old boolean read a degraded
    restrict as full enforcement (the defect above, reproduced at this
    exact call site), so widening the warn condition to include
    `"degraded"` is the direct fix now that the two are distinguishable
    — the fence's policy (quiet by default, warn only when
    `COSMIC_FENCE` is set, dispatch proceeds either way) is unchanged.
- **rejected:**
  - gating the nothing-enforced refusal on "more than one section
    requested" (so a single-section `best_effort` caller would still
    get a bare truthy value) — this silently revives the exact footgun
    for the more common single-section shape, which is what this
    record exists to close.
  - matching the error string (e.g. `err:find("nothing enforced")`) to
    let `fence()` tolerate the all-skipped case instead of adding
    `allow_unenforced` — this is the fragile-by-construction pattern
    [D24](d24-structured-failures.md) argues against for structured
    failure sites, and `cosmic.sandbox` has no structured error record
    to classify on instead; a named, validated option is the honest
    version of the same intent.
  - keeping `Availability`/the boolean `Report` alongside the new
    shapes for compatibility — a facade whose whole job is honest
    fail-closed reporting cannot ship two ways to ask the same
    question where one of them lies by omission.
- **consequences:** every in-tree caller that read `sandbox.apply`'s
  return value as a boolean or read `availability().fs`/`.sys` as a
  boolean needed updating in this same change (`_cli/driver.tl`,
  `_cli/fence_test.tl`); `cosmic/quicksand/box/run.tl`'s two `apply`
  call sites do not read fields off the return value and needed no
  change. A caller instantiating a policy literal across a version
  boundary that still sets `Options.handled` now gets an unknown-field
  type error rather than a silently-ignored tuning knob — acceptable
  per [D10](d10-right-to-break.md). What would make us revisit: a
  second mechanism gaining its own partial-enforcement concept (unveil
  or pledge growing an ABI-like versioned capability set) would need
  `Section.state`/`missing` generalized beyond landlock's
  REFER/TRUNCATE-only degrade today.
