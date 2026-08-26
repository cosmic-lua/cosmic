# D23 — cosmic.check throws by design; needs/reap may exit

- **date:** 2026-08
- **status:** amended 2026-08, twice (the unreachable-nil assert rule; the throw/exit census)
- **context:** the error-handling doctrine says "never throw from
  library code" with no carve-out, yet every assertion in
  `cosmic.check` throws — deliberately, at error level 2, so the
  failure points at the test's line — and two functions go further and
  `os.exit`: `needs` exits `EXIT_SKIP` when a precondition is missing
  (a printed "skip" that returns would exit 0, and the runner counts 0
  as a pass), and `reap` ends the file when a forked child announced a
  skip or failure through the only channel a child has, its exit code.
  AGENTS.md granted the exception to `must` alone; the module's actual
  behavior had no record to stand on.
- **decision:** `cosmic.check` is the one module exempt from the
  `nil, string` convention.
  - Its assertions (`equal`, `not_equal`, `truthy`, `failed`, `must`)
    **throw** on failure: a test's caller is the test runner, the
    runner grades a file by its exit, and an uncaught error IS the
    failing grade. Returning `nil, string` from an assertion would
    make every test line a two-value dance that tests exist to avoid.
  - `needs` and `reap` may **exit the process**, because the runner
    grades exit codes and `records.EXIT_SKIP` is the one channel that
    distinguishes "cannot run here" from "passed" — a helper that only
    returned could be forgotten, and a forgotten exit turns a skip
    into a silent pass.
  - **No other `cosmic.*` module may throw or exit.** The only other
    sanctioned throws are D22's: CSPRNG contract violations and a
    broken kernel CSPRNG. A library that throws steals the caller's
    error handling; check is exempt precisely because its caller is
    the runner, not library code.
- **rejected:** `nil, string` assertions (every test line becomes
  `assert(check.equal(...))` — the wrapper the module exists to
  delete); a separate always-throwing `check.strict` beside a
  returning `check` (two modules, one purpose, and the returning one
  is the footgun); keeping the exemption as an AGENTS.md aside (the
  doctrine's one exception deserves a record, not a footnote).
- **consequences:** `check` stays test/example-only — library code
  must never require it (`must` throws, so a library caller would
  inherit throwing behavior it may not have). The doctrine line in
  AGENTS.md points here. The runner's grading contract
  (`records.status_of`, `EXIT_SKIP`) is what makes the exits correct;
  if that contract ever changes, this record is the dependency to
  revisit.
- **amended 2026-08 (the closed list becomes a rule):** "no other
  `cosmic.*` module may throw or exit" was written as a list of two
  named exemptions, and a third shape turned up that is neither: a
  `cosmo.*` binding whose declared `| nil` is honest for an arbitrary
  caller-supplied argument and IMPOSSIBLE for the constants a cosmic
  module hands it. `cosmic.time.now()` reads
  `unix.clock_gettime(unix.CLOCK_REALTIME)`, whose `integer | nil`
  first slot can only be nil for a clock id the kernel rejects — not
  for either of the two constants this module passes — and declaring
  `integer` over it is the type lie the honest-nil doctrine forbids.
  So the exemption is a rule rather than a longer list: **a `cosmic.*`
  module may `assert` a `cosmo.*` binding return whose declared `| nil`
  is unreachable for the arguments that call passes, provided the
  assert carries a trailing `-- assert: <why the nil cannot occur>`
  comment naming the reason**, the way a cast carries its `-- cast:`.
  Nothing else moves: a REACHABLE runtime failure stays D22's shape
  (no caller may proceed without the value), a caller contract
  violation stays D22's other shape, and each still needs its own
  record. A third named module was rejected because the shape is not
  about `cosmic.time` — `cosmo.path.join` declares `string | nil` for
  a nil no caller can reach across 26 sites of the same census — so an
  enumerated list would need a fresh amendment per module, and a seat
  on it records only that somebody once said yes, where the comment
  records the argument a reader can check.
- **amended 2026-08 (the throw/exit census):** the first amendment
  closed the assert shape; a census over `error(` and `os.exit(` in
  library code then found four more shapes the closed list never
  named, all already in the tree and all correct where they sit.
  Licensed as rules, the way the assert shape was:
  - a post-`fork` child path may `os.exit` — a child that failed its
    `chdir` or `exec` cannot return into two copies of the caller's
    stack, and 126/127 are the exec-failure grammar every shell reads
    (`cosmic/child/init.tl`, `cosmic/quicksand/box/run.tl`);
  - an entry helper whose caller is the OS may `os.exit` with the
    code it computed — `cosmic.main()` and the generated embed
    wrapper exist to turn a return value into a process status;
  - a wrapper whose job is transparency may re-raise the wrapped
    code's own error unchanged (`error(e, 0)`): swallowing or
    re-typing it would change observable behavior
    (`cosmic.coverage`'s coroutine shim);
  - a caller-contract throw guarding an enum-typed argument is
    licensed when the argument's type already makes the throw
    unreachable for typed callers and the doc comment names the
    contract (`cosmic.hash`'s unknown-algorithm throw) — the record
    the first amendment said such a throw still needed is this
    bullet.
  A reachable runtime failure still returns; nothing here licenses
  one. No gate checks these shapes yet — the assert-justify lint
  checks its comment convention and nothing reads `error(` or
  `os.exit(` — so the census that made this amendment true is
  follow-up lint work on the board.
