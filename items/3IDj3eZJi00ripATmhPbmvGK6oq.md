## Evidence

Found while implementing wave 2 (3I7LEsGv), which stops at the ABI 9
ceiling its spec names. The kernel uapi has since documented ABI 10, so
whilp/cosmopolitan's `libc/calls/landlock.h` is one tier behind the
kernel again:

- `LANDLOCK_ACCESS_NET_BIND_UDP` (1ULL << 2) and
  `LANDLOCK_ACCESS_NET_CONNECT_SEND_UDP` (1ULL << 3) — UDP local-port
  and peer restriction, the first UDP the kernel has ever offered, so
  wave 1's "no UDP (the kernel has none)" non-goal has expired.
- `LANDLOCK_ADD_RULE_QUIET` (1U << 0) — the first non-reserved
  `landlock_add_rule` flag; the Lua wrapper already passes `flags`
  through, so this needs only a constant.
- `landlock_ruleset_attr::quiet_access_fs`, `::quiet_access_net`,
  `::quiet_scoped` — three more struct fields, which move the
  create_ruleset size a fourth time. The
  `LANDLOCK_RULESET_ATTR_SIZE(member)` rule and the wrapper's
  argument-presence gating already generalise, so this repeats wave 2's
  shape exactly.

Separately, and inside the ABI 5-9 ceiling rather than beyond it:
`LANDLOCK_CREATE_RULESET_ERRATA` (1U << 1, the ABI 7 era) is still
unbound. It is a `create_ruleset` flag, not an access right, scope or
restrict flag, so it fell outside wave 2's enumerated Change list and
was deliberately left out there. The wrapper already passes `flags`
through, so it too needs only a constant — and without it a caller
cannot query the errata bitmask at all.

Sources: `include/uapi/linux/landlock.h` and
`Documentation/userspace-api/landlock.rst` on torvalds/linux, read
2026-08-21.

## Why it might matter

The downstream consumer of these bindings is cosmic's sandbox facade,
whose stated target is the newest ABI the kernel documents. Every tier
the C layer lacks is a tier the facade cannot offer, and the pattern of
letting one wave land and the next open keeps the gap bounded. UDP in
particular is a capability the facade's `net` section has no way to
express today.
