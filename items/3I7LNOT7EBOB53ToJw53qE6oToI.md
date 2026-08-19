> Capture note, 2026-08-19: spec refined to the ready bar; filed unparented because plan and ready sat at their limits. Attach under 3I1IfJ22 (the G2 sandbox epic) and promote when a slot opens; blocked_by edges to record at attach time are in the "Blocked by" section (ids: R1 report = 3I7LBrUN, wave-1 bindings = 3I7LDODd, wave-2 bindings = 3I7LEsGv, pin bump 1 = 3I7LGcLa).

## Goal

G2 — quicksand's Box consumes the same net tier: on Linux hosts where
the netns cannot start (unprivileged userns disabled), a Box still gets
port-level TCP containment instead of nothing.

## Change

1. **`cosmic/quicksand/init.tl`** (measured: `capabilities()` at ~147
   already computes `has_landlock` via the shared probe, PR #1278):
   capabilities gain `landlock_net: boolean` — true when the probed ABI
   is ≥ 4 (read from `cosmic.sandbox.landlock`, the one cached probe).
2. **Box setup**: when a Box's network policy is requested and
   `net_ns` is unavailable but `landlock_net` is true, apply the
   sandbox `net` section in the child after fork — defense in depth:
   when the netns IS available, both apply (the netns for isolation,
   the port tier as backstop). The Box's report/why-degraded surface
   states which tier is in effect, using the same full/degraded/skipped
   vocabulary the R1 report standardized.
3. **Tests**: a Box on a netns-less, ABI-4 host confines connect to the
   allowed ports (CI ubuntu exercises it); the capability flag pins in
   the existing capabilities test.

## Non-goals

- no change to the proxy or its allowlist grammar — hostname policy
  stays the proxy's; ports are the only new tier.
- no weakening: a host with neither netns nor ABI 4 reports exactly
  that, and a non-best-effort Box refuses as it does today.

## Blocked by

The sandbox `net` section slice — mirrored in `blocked_by`.

## Acceptance

- `bin/cosmic --make test cosmic/quicksand/init_test.tl` ends
  `test: PASS (1 files)`.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed once the net section lands; the capability plumbing mirrors
the existing `has_landlock` line it sits beside.
