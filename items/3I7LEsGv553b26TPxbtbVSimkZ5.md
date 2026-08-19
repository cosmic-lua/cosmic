## Goal

G2, requirement R6, waves 2–3 of whilp/cosmopolitan#266: the C layer
reaches the newest Landlock ABI the kernel documents (9 at the 2026-08
review) — every remaining access right, scope, and restrict flag. PR
lands in **whilp/cosmopolitan** (cross-repo field when 3I3z2gOF lands).

## Change

All names, values, and struct offsets are taken VERBATIM from the
current kernel uapi `linux/landlock.h` at implementation time — the
authoritative source this spec deliberately does not transcribe. What it
does fix:

1. **`libc/calls/landlock.h`**: ABI 5's device-ioctl fs bit; ABI 6's
   `scoped` ruleset field and its `LANDLOCK_SCOPE_*` bits
   (abstract-unix-socket, signal); ABI 7's audit/logging restrict_self
   flags; ABI 8's all-threads (TSYNC-style) restrict flag; ABI 9's
   additions. Each with the header's `@note ABI N+` doc style.
2. **`third_party/lua/lunix.c`**: `landlock_create_ruleset` gains the
   `scoped` mask as its next optional argument, size-gated by argument
   presence exactly per wave 1's rule (fs-only calls keep sending
   fs-only bytes); `landlock_restrict_self`'s flags argument passes the
   new flags through (measured: the wrapper already takes flags —
   only constants are needed). Register every new constant; no existing
   signature moves.
3. **`tool/net/definitions.lua`** in the same commit, per the ratchet.

## Non-goals

- no new rule TYPES beyond what the uapi defines through the reviewed
  ceiling; no speculative bits for unreleased kernels.
- no Lua-surface convenience layers — raw constants and passthrough;
  ergonomics live in cosmic's Teal layer.
- frozen existing contracts, surgical diff, as wave 1.

## Blocked by

Wave 1 (same two files; landing order is real) — mirrored in
`blocked_by`.

## Acceptance

In a whilp/cosmopolitan checkout on this item's branch:

- `make -j$(nproc) o//tool/lua/test` passes.
- `o//tool/lua/lua -e '...'` printing each new constant non-nil, and an
  fs-only `landlock_create_ruleset` still succeeding (size gating
  holds).

## Enablement

none needed — wave 1 settles the additive-API and size patterns this
repeats; the uapi-verbatim rule keeps ABI 7–9 names from being invented
from memory.
