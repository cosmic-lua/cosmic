## Goal

G2, requirement R6, wave 1 of whilp/cosmopolitan#266: the C layer learns
Landlock ABI 4 — per-port TCP policy — the tier everything downstream
(the cosmic `net` section, quicksand's unprivileged port containment)
builds on. The PR for this item lands in **whilp/cosmopolitan** (the
board's cross-repo field, 3I3z2gOF, is in ready; set it on this item
when it lands — until then this line is the record).

## Change

Measured 2026-08-19 at whilp/cosmopolitan `0980e033`:

1. **`libc/calls/landlock.h`**: `struct landlock_ruleset_attr` (today
   only `handled_access_fs`) gains `uint64_t handled_access_net`;
   `enum landlock_rule_type` gains `LANDLOCK_RULE_NET_PORT = 2`; add
   `struct landlock_net_port_attr { uint64_t allowed_access; uint64_t
   port; }` and bits `LANDLOCK_ACCESS_NET_BIND_TCP` /
   `LANDLOCK_ACCESS_NET_CONNECT_TCP` — values verbatim from the kernel
   uapi `linux/landlock.h`, with doc comments in the header's existing
   style (`@note ABI 4+`).
2. **The size trap, settled — this is the wrong turn to not take.**
   `LuaUnixLandlockCreateRuleset` (`third_party/lua/lunix.c` ~1091)
   passes `sizeof(attr)` today; once the struct widens, that would send
   pre-6.7 kernels a size they do not know, and Landlock's contract
   answers E2BIG. The wrapper must choose the size by what the caller
   asked for: fs-only call → size through `handled_access_fs`
   (`offsetofend`-style, the exact bytes today's binary sends, so every
   existing caller is bit-identical); a call with a net mask → size
   through `handled_access_net`.
3. **Additive Lua surface**, existing signatures frozen:
   `unix.landlock_create_ruleset(handled_fs[, flags[, handled_net]])` —
   the argless ABI-probe form and the 1–2 arg forms unchanged; new
   `unix.landlock_add_net_rule(ruleset_fd:int, port:int, allowed:int)`
   for `LANDLOCK_RULE_NET_PORT` (a new function, so the 4-arg
   path-beneath `landlock_add_rule` contract does not move). Register
   the two NET constants beside the FS block (~4906–4930).
4. **`tool/net/definitions.lua` in the same commit** (constants block
   ~3971, function annotations ~7405) — the annotation-coverage ratchet
   in the test target enforces it.

## Non-goals

- no change to any existing binding's signature, return shape, or
  constant value — frozen at the C boundary for cosmic's generated
  types.
- no ABI 5–9 material (the sibling wave-2 item), no UDP (the kernel has
  none), no cosmic-side changes.
- surgical diff, mergeable with upstream jart/cosmopolitan.

## Acceptance

In a whilp/cosmopolitan checkout on this item's branch:

- `make -j$(nproc) o//tool/lua/test` passes (binding tests + annotation
  ratchet).
- `o//tool/lua/lua -e 'unix=require"unix"; print(unix.LANDLOCK_ACCESS_NET_CONNECT_TCP)'`
  prints 2 (on the dev host, kernel 6.8 = ABI 4, a full
  create/add-net-rule/restrict round-trip is exercisable in the binding
  test).
- an fs-only `landlock_create_ruleset` call still succeeds on the same
  host (the size-gating proof).

## Enablement

none needed — the size-by-argument rule above is the one predicted
wrong turn, settled in the spec; whilp/cosmopolitan#266 carries the
same plan for reviewers on that side.
