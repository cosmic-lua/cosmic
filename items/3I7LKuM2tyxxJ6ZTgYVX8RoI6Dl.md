## Goal

G2 — the facade reaches the full reviewed ceiling (ABI 9): every right
the kernel can enforce is handled and reported — device ioctl (5),
signal and abstract-unix-socket scoping (6), audit (7), all-threads
restrict (8), ABI 9's additions — so "sandboxed" means the kernel's
best on every kernel.

## What is settled

- Mechanical adoptions, no vocabulary needed: the all-threads restrict
  flag is applied whenever ABI ≥ 8 (single-threaded today, correct the
  day the runtime is not — the epic's thread-scope friction); ABI 5's
  ioctl-dev bit joins the fs masks (`abi_mask` gains the ≥5 rung) and
  degrades honestly below.
- Everything flows through the R1 report — new rights strip into
  `"degraded"` like TRUNCATE does today, never silently.

## Still to settle (why this item holds in plan)

- The scoping vocabulary: is ABI 6's signal/abstract-socket scoping a
  new policy section (`scope = {...}`), part of `sys`, or applied
  implicitly whenever the policy has any section? Implicit is tempting
  (a sandboxed process rarely wants cross-scope signals) but widens
  behavior under existing policies — needs the goal owner's read.
- Audit (ABI 7): expose the log-control flags or leave them at their
  kernel defaults? Exposure is API surface with no in-tree consumer
  yet.
- Which ioctl-dev grants belong in the composite masks (`rw` on a
  device node wants ioctl; a plain tree does not).

Refine against the landed wave-2 pin: the exact constants to write
these against exist only after it, which is what `blocked_by` encodes.

## Non-goals

- no copying of go/rust-landlock's builder surfaces — the declarative
  table stays the one door.
- no emulation on kernels below a feature's ABI.

## Blocked by

The R1 report slice, the ABI 5–9 bindings, and the wave-2 pin bump —
mirrored in `blocked_by`.

## Acceptance

Sketch until the vocabulary settles: `--make ci` green; per-right tests
in the ABI-gated style the net slice establishes; the report showing
`"full"` on a ≥9 kernel for a policy exercising each new right.

## Enablement

the open questions above are this item's remaining plan-phase work; the
mechanical halves are already stated so a refiner starts from decisions,
not archaeology.
