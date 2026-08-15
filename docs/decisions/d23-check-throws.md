# D23 — cosmic.check throws by design; needs/reap may exit

- **date:** 2026-08
- **status:** active
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
