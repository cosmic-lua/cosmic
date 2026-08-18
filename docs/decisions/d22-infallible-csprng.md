# D22 — the CSPRNG surface is infallible; a broken one crashes

- **date:** 2026-08
- **status:** amended 2026-08 (adds a seedable, non-crypto source beside the CSPRNG)
- **context:** `cosmic.rand` was fallible end to end — even
  `rand.float(): number | nil, string`, which calls `int(0, 2^53-1)`
  with constants and cannot fail — because one argument-range check on
  `bytes` propagated `| nil, string` through the whole module. Meanwhile
  `uuid.v4()` draws from the same kernel CSPRNG and returns bare
  `string`. One of the two was wrong about the same operation, and the
  fallible one taxed every call site with a dead nil-check. Go tried
  both answers and settled this in Go 1.24: `crypto/rand.Read` never
  returns an error (it crashes if the kernel CSPRNG is truly broken,
  because error returns invited limping on insecurely), and argument
  errors panic. Python and Rust land the same way.
- **decision:** the CSPRNG surface (`rand.*`, `uuid.*`) is infallible.
  - Runtime failure of the kernel CSPRNG is treated as impossible on
    supported platforms; if the binding ever reports one, the wrapper
    **throws** — the one sanctioned violation of "never throw from
    library code" outside `cosmic.check`, because no caller may proceed
    without the entropy it asked for.
  - Out-of-range arguments (`bytes(0)`, `int(10, 1)`, `token(0)`) are
    contract violations and throw with a message naming the contract.
  - `choice({})` returns `nil` — an honest answer about an empty list,
    not a failure; it is the module's only nil.
- **rejected:** leveling `uuid` up to `string | nil, string` (adds a
  dead nil-check to every uuid call for a failure that cannot happen);
  keeping per-argument `nil, string` (the checker cannot distinguish
  "caller bug" from "runtime failure", so both were handled, badly, at
  every site).
- **consequences:** `rand.bytes/int/float/token/shuffle` return bare
  values; callers deleted their nil-checks. The doctrine sentence to
  carry: a *contract violation* is the caller's bug and may throw; a
  *runtime failure* belongs in the return channel — and a module whose
  only failures are contract violations is infallible.
- **amended 2026-08 (seedable non-crypto source added):** `rand.insecure_source(seed)`
  adds a second, deliberately-insecure surface in the same module: an
  object (`rand.Source`) with its own private state, seeded and
  reproducible, for callers that need randomness to replay
  (fuzz-adjacent jitter/backoff, generated fuzz inputs) rather than to
  be unguessable. It does not touch this decision's guarantee:
  `rand.bytes`, `rand.int`, `rand.float`, `rand.choice`,
  `rand.shuffle`, `rand.token`, and `uuid.*` stay infallible,
  unseedable, and CSPRNG-backed exactly as decided above. The two
  surfaces stay visually distinct at every call site —
  `insecure_source`/`insecure64` carry the same `insecure` marker, and
  a `Source`'s methods are always called on an object a caller
  explicitly constructed (`src:int(...)`), never on the bare `rand.*`
  namespace — so a call site cannot drift from one meaning to the
  other. `Source` throws on a contract violation (`min > max`), the
  same convention `rand.int` already uses; it carries no
  runtime-failure return slot either, but for an ordinary reason, not
  D22's: it has no kernel dependency to fail.
