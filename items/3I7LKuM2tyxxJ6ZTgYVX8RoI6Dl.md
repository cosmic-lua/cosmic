## Goal

G2 — the facade reaches the full reviewed ceiling (ABI 9): every right
the kernel can enforce is handled and reported — device ioctl (5),
signal and abstract-unix-socket scoping (6), all-threads restrict (8),
ABI 9's additions — so "sandboxed" means the kernel's best on every
kernel.

## Owner decisions, 2026-08-19

Scoping is a **new policy section** — not folded into `sys`, not applied
implicitly (implicit was considered and rejected: it would change
behavior under existing policies). Audit (ABI 7) is **not exposed**:
kernel defaults stand until an in-tree consumer earns the surface.
Device ioctl **rides `rw`**, the same composite TRUNCATE already rides —
R2's "a tree granted rw supports every ordinary file operation" applied
to device nodes.

## Change

Blocked on the wave-2 pin (the constants this writes against) and the
R1 report shapes; the vocabulary is settled now:

1. **`cosmic/sandbox/init.tl`**: `record Scope` —
   `signal: boolean`, `abstract_unix: boolean` — and
   `Options.scope: Scope`. `true` confines that category to the sandbox
   domain (Landlock scoping is deny-outside, not per-target grants, so
   booleans are the honest shape — there is nothing path-like to list).
   Absent section: no scoping. `validate` accepts only the two keys.
2. **`cosmic/sandbox/landlock.tl`**: the `scoped` mask reaches
   `unix.landlock_create_ruleset`; `abi_mask` learns the ≥5 rung
   (IOCTL_DEV joins the `WRITE` composite beside TRUNCATE, stripped
   below ABI 5 — its doc comment carries the R2 rationale) and the ≥6
   rung for scopes. Below the needed ABI: `strict` refuses; otherwise
   the section reports `"degraded"`/`"skipped"` through the R1 grammar,
   never silently.
3. **TSYNC**: `restrict` passes the all-threads flag whenever ABI ≥ 8 —
   unconditional, no vocabulary (single-threaded today, correct the day
   the runtime is not; the epic's thread-scope friction closes).
4. **ABI 9**: adopt its additions uapi-verbatim under the same
   pattern — handled when expressible, reported when not.
5. **Report**: `Report.scope: Section`, same grammar as fs/sys/net.
6. **Tests**: the ABI-gated style the net slice establishes — skip on
   probed ABI below the feature, live on CI kernels at or above it; a
   scoped policy on an ABI ≥ 6 kernel refuses a signal to an
   outside-domain process (fork a peer pre-restrict, signal
   post-restrict, assert EPERM); ioctl-dev: an `rw` grant on a tty/dev
   fixture keeps isatty(3) working inside the tree on ABI ≥ 5.

## Non-goals

- no audit/log flag exposure (decision above); no builder-pattern
  surfaces; no emulation below a feature's ABI.
- no new section beyond `scope`; pathname-socket material lands only as
  what the uapi actually defines for ABI 9.

## Blocked by

The R1 report slice (3I7LBrUN), the ABI 5–9 bindings (3I7LEsGv), and
the wave-2 pin bump (3I7LNDrF, at attach) — mirrored in `blocked_by`.

## Acceptance

- `bin/cosmic --make test cosmic/sandbox/init_test.tl cosmic/sandbox/landlock_test.tl cosmic/sandbox/landlock_net_test.tl`
  ends `test: PASS (3 files)` (file set final at implementation; the
  scope/ioctl pins land where the net slice put its ABI-gated peers).
- `bin/cosmic --make ci` ends `ci: PASS`.
- the PR quotes the ubuntu-lane run showing which ABI the runner
  reported and which tests ran live vs skipped — the honest ceiling
  statement this epic is about.

## Enablement

none needed — all three vocabulary questions are now settled owner
decisions recorded above; the constants arrive via the blocked_by chain.
