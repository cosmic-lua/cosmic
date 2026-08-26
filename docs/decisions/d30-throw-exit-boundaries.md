# D30 — a cosmic module throws or exits only where no caller could receive the value

- **date:** 2026-08
- **status:** active
- **context:** the error-handling doctrine says "never throw from
  library code", and D23 closes with "no other `cosmic.*` module may
  throw or exit" — exempting `cosmic.check` (D23), the CSPRNG (D22),
  and an `-- assert:`-licensed unreachable nil (D23's amendment). A
  census of the whole library (word-boundary `error(` and `os.exit(`
  over `cosmic/**`, tests and examples excluded) found 19 sites in
  seven modules outside those exemptions: the module searcher's six
  load-failure raises, `cosmic.teal`'s require-time raise when the
  compiler is absent, the coverage module's `coroutine.wrap` re-raise,
  seven exits on post-`fork` child paths in `cosmic.child` and
  `cosmic.quicksand.box`, `cosmic.main`'s exit in `cosmic/init.tl`,
  and three throws in `cosmic.hash`. Each is correct where it sits,
  and none was recorded anywhere — the doctrine's real boundary was
  remembered, not written. D23's amendment had already flagged half of
  the gap: a caller-contract violation "still needs its own record".
- **decision:** a `cosmic.*` module may throw or exit **only where no
  caller could receive the value**, which is exactly three shapes:
  - **a Lua protocol whose error channel is the throw.** A package
    searcher/loader raises when it finds a module it cannot load —
    `require`'s contract distinguishes "not found here" (a returned
    string) from "found but broken" (a raise), and returning
    `nil, string` from a loader silently means the former. The same
    licence covers a `coroutine.wrap` shim re-raising a failed
    `resume`, because stock `coroutine.wrap` does, and a module whose
    own `require` raises when a hard dependency is absent — a failed
    `require` IS the reporting channel. The sites: `cosmic.searcher`,
    `cosmic.teal`'s load-time compiler probe, `cosmic.coverage`'s
    wrap shim.
  - **a process boundary.** A post-`fork` child whose setup or `exec`
    failed writes the error to its parent's pipe and exits — returning
    would run the parent's continuation in two processes — and an
    entry helper whose documented job is turning a main function's
    return into the process's exit status answers to the OS, not to a
    caller. The sites: `cosmic.child`'s spawn child, the
    `cosmic.quicksand.box` supervisor and workload children,
    `cosmic.main` in `cosmic/init.tl`. (The generated artifact entry
    wrapper in `cosmic.embed` won the same argument in review before
    this record existed.)
  - **an infallible-by-type contract violated past the checker.**
    `cosmic.hash`'s `digest`/`hmac` take a typed `Algo` enum, so the
    checker already rejects every bad algorithm; a value smuggled past
    it through a cast is a caller-contract violation and throws, and a
    binding failure that is unreachable for a valid enum member throws
    for the same reason. This is the per-module record D23's
    amendment demanded for the shape D22 pioneered.

  every such site carries a trailing justification — `-- throws: <why>`
  on an `error(` line, `-- exits: <why>` on an `os.exit(` line, or
  either on the line directly above when the 90-column width won't fit
  it — the same grammar contract as `-- cast:` and `-- assert:`.
  `cosmic/check.tl` and `cosmic/rand.tl` carry no per-site comments:
  their exemptions are module-level, recorded in D23 and D22.
- **rejected:** returning `nil, string` from a loader (breaks
  `require`'s found-but-broken channel — the failure would read as
  "module not found" with the real error swallowed); returning after a
  failed `exec` in a forked child (two processes run the caller's
  continuation, the bug the exit exists to prevent); a module
  allowlist without per-site comments (D23's amendment already
  rejected the seat-on-a-list shape — a list records that somebody
  said yes, the comment records the argument a reader can check); a
  second D23 amendment instead of this record (D23 is check's record,
  and none of these shapes is about check).
- **consequences:** the doctrine's boundary is now checkable at each
  site instead of remembered: a reader at any `error(`/`os.exit(` line
  finds the argument beside it, and a new site with no justification
  is a bug even before a lint demands one (the enforcement lint is
  filed to follow, the way `-- assert:`'s did). The cost is the
  comment's maintenance: a site whose reason changes must change its
  comment, and a justification that no longer holds is exactly the
  signal to return `nil, string` instead. What would make us revisit:
  a fourth shape turning up — the rule stays "no caller could receive
  the value", and a site that cannot say why in one line does not
  qualify.
