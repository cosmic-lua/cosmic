Imported from whilp/cosmic#1219.

## Goal

G2 — contained where the platform can enforce it.

## Outcome

`cosmic.sandbox.apply` enforces every access category the running
kernel can enforce, and its return value says exactly what was
enforced, degraded, or skipped — so &#34;sandboxed&#34; never silently means
less than what was asked, on any kernel. Observable when it holds:

- a policy granting `rw` on one tree permits a cross-directory rename
  inside that tree on a Landlock ABI ≥ 2 kernel (today it is denied
  everywhere, by omission).
- a structurally valid policy never dies with a kernel `EINVAL`; bad
  narrowing fails at `validate`, before anything is applied.
- an **ABI drift alarm** exists: a test fails when the running kernel
  reports a Landlock ABI above the highest one cosmic models, so a
  kernel bump reopens this work instead of silently widening the
  unenforced surface.
- the enforcement report distinguishes *full* / *degraded* /
  *skipped* per section, carries the mechanism and ABI, and a caller
  can demand full enforcement (`strict`) as the counterpart of
  `best_effort`.
- a `net` section (`net = { connect_tcp = {443}, bind_tcp = {} }`)
  enforces per-port TCP policy on ABI ≥ 4 kernels — containment for
  hosts where unprivileged user namespaces are disabled and
  quicksand&#39;s netns cannot start.

## Where we stand (evidence, 2026-08)

Reviewed against the two reference implementations — go-landlock and
rust-landlock, both current to Landlock ABI 9 — cosmic models ABI 3
(Linux 6.2, early 2023). Landlock&#39;s core rule is that an access right
absent from `handled_access_fs` is **unrestricted**, so each unmodeled
ABI level is unenforced surface that widens as kernels ship: TCP
connect/bind (ABI 4, 6.7), ioctl on device nodes (ABI 5, 6.10),
signal + abstract-unix-socket scoping (ABI 6, 6.12), audit control
(ABI 7), all-threads TSYNC (ABI 8), pathname unix sockets (ABI 9).
The ceiling is in the C layer: `struct landlock_ruleset_attr` in
`libc/calls/landlock.h` (whilp/cosmopolitan) has only the ABI-1
field, and `lunix.c` exposes only `LANDLOCK_RULE_PATH_BENEATH`.

Four defects in the Teal layer, independent of the ceiling:

1. **`handled` never intersects rule access.** `landlock.tl` masks
   `handled` and each rule&#39;s access by the ABI mask but never by each
   other; per landlock_add_rule(2), a rule whose access is not a
   subset of the handled set is `EINVAL`. Any caller narrowing
   `handled` (a public field on `sandbox.Options`) fails at the first
   rule. Unhit in-tree only because nothing passes it.
2. **`REFER` is handled but never granted.** `ALL` includes `REFER`
   so it lands in the handled set, but no group mask in
   `cosmic/sandbox/plan.tl` carries it — cross-directory rename/link
   is denied even between two directories inside the same `rw` grant.
   The libc&#39;s own unveil path grants `REFER` with `&#34;r&#34;`
   (`libc/calls/unveil.c`), so the facade is silently stricter than
   the mechanism it fronts. `fs.write_atomic` escapes only because
   mkstemp stages beside the destination.
3. **`fs.optional` pre-checks existence** (`cosmo_path.exists` before
   the open): TOCTOU — a path vanishing between check and open still
   kills the whole restrict — and dangling symlinks pass the check
   then fail the open. go-landlock&#39;s per-rule `IgnoreIfMissing`
   tolerates `ENOENT` at open time instead; race-free and deletes
   `present_only`/`effective_fs` outright. `_cli/grants.tl` already
   hand-rolls its own presence filter to route around this.
4. **Silent ABI downgrade reported as full enforcement.** On a
   5.13–6.1 kernel `abi_mask` strips `TRUNCATE`/`REFER` and `apply`
   still returns `{fs = true}` — enforcement weaker than asked,
   invisible to the caller. Related footgun: under `best_effort`,
   `apply` returns a *truthy* `{fs = false, sys = false}` when
   nothing was enforced, so the natural `if sandbox.apply(p) then`
   is wrong.

Smaller frictions: three uncoordinated Landlock probes
(`landlock.abi`, `unveil.available`, `quicksand.probe_landlock`);
thread scope undocumented (`landlock_restrict_self` binds the calling
thread — moot while the runtime is single-threaded, wrong the day it
is not; ABI 8 TSYNC is the fix both reference APIs adopted); the libc
unveil path&#39;s seccomp supplement (truncate below ABI 3, setxattr
always) is bypassed by cosmic&#39;s direct-landlock path and only the
truncate half is documented.

## The end state, as requirements

- **R1 — honest report.** `apply` never returns success while
  enforcing less than requested without saying, per section, what was
  degraded or skipped and why. `availability()` carries the ABI and
  the effective handled mask, not two booleans.
- **R2 — `rw` means rw.** A tree granted `rw` supports every ordinary
  file operation inside it — including cross-directory rename/link
  and `O_TRUNC` — on kernels that can express it.
- **R3 — no constructible `EINVAL`.** Options that narrow (or their
  removal — `handled` is unused in-tree and Linux-only on a
  cross-platform record; dropping it is on the table) cannot produce
  a kernel error a validate pass could have caught.
- **R4 — race-free optional.** Missing paths are tolerated at open
  time (`ENOENT` skips the rule), not pre-checked.
- **R5 — one probe.** ABI knowledge lives in one cached place; the
  unveil shard becomes OpenBSD-only; quicksand consumes the same
  probe.
- **R6 — the C ceiling tracks the kernel.** whilp/cosmopolitan&#39;s
  bindings expose the full modern Landlock surface: widened ruleset
  attr (`handled_access_net`, `scoped`), `LANDLOCK_RULE_NET_PORT`,
  the ABI 4–9 access/scope bits, the TSYNC restrict flag — with
  `definitions.lua` updated in the same commit (frozen-contract
  rule), then a cosmos pin bump here.
- **R7 — a `net` section.** Same declarative vocabulary, consumed by
  quicksand&#39;s Box too; the proxy keeps hostname/HTTP-level policy,
  landlock net owns the port tier.
- **R8 — recorded posture.** Enforcement-report semantics (degraded
  vs refused, D3 vs D7 tension) and the fence&#39;s scope (fs-only today;
  whether it grows sys/net; the setxattr/ioctl gap) each get a
  decision record — amend D7 or add a new one via the `decide` skill.

## Decomposition sketch

Phase 1 — Teal-only correctness, no C change, mutually independent:
defect 1 (+ the `handled` field decision), defect 2 (`REFER` with
`rw` on ABI ≥ 2), defects 3–4, the single probe, the report/strict
rework, the drift alarm.

Phase 2 — the C ceiling, on whilp/cosmopolitan&#39;s board (cited here by
URL; `Blocked by:` is same-repo only): binding slices per R6, then a
release and a pin-bump slice here.

Phase 3 — the facade grows `net` (blocked on the pin bump), quicksand
consumes it, fence posture decided and recorded (R8), TSYNC adopted,
docs state what fs policy cannot govern.

Children (checklist filled as slices open; epics close when the
outcome above holds, not when the list empties):

- [ ] (phase-1 slices, to be cut as `work:plan` drains)

## Non-goals

- copying the reference APIs&#39; surfaces (builder pattern, `RODirs`
  vs `ROFiles` splits). The declarative `{fs, sys}` table is the
  right door; this epic is entirely beneath it.
- portable default-deny — a goals.md non-goal; unenforcing platforms
  stay honest, never emulated.
- replacing quicksand&#39;s netns/proxy. Landlock net is the lighter,
  unprivileged tier beside it, not a successor.
- weakening any existing denial to make a report look better.

## Verification when closing

- the fence&#39;s own tests still prove a real denial (`_cli/fence_test`)
  and a fenced build of this repo passes.
- a sandbox test proves cross-directory rename inside one `rw` grant
  on an ABI ≥ 2 kernel, and the drift-alarm test is red iff the
  kernel&#39;s ABI exceeds cosmic&#39;s model.
- `bin/cosmic --make ci` ends `ci: PASS` with the new report shapes
  under coverage.


---
_Generated by [Claude Code](https://claude.ai/code)_