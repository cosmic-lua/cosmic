## Goal

`tool/lua/test_definitions_coverage.lua`'s annotation-quality ratchet
checks that a binding's `definitions.lua` annotation is present and
that its declared return arity matches what the C source actually
pushes — it does not check that a declared slot's TYPE matches what
that slot actually holds at runtime. A binding whose annotation gets
the arity right but assigns the wrong type to a shared/doubling slot
(the exact class of bug the `unix.nanosleep`/`unix.tiocgwinsz`-family
fixes exist to correct) passes the ratchet both before and after such
a fix, so the ratchet cannot itself catch a regression that reintroduces
the same mislabeling.

## Evidence

Found live during the build of board item `3IiFbfUJTDG5D8ovqA8IzNoHNOt`
(`unix.tiocgwinsz`'s annotation fix, PR #335, cosmic-lua/cosmopolitan).
The builder's own mutation test: reverted `unix.tiocgwinsz`'s
`definitions.lua` annotation to the pre-fix, WRONG shape (a fixed
4-slot `rows, cols:integer, error:string?, errno:unix.Errno?`, when the
C implementation only ever returns 2 values on success or 3 on
failure, with the error string landing in the declared `cols` slot),
then re-ran `make -j4 o//tool/lua/test`. The full suite — including
`test_definitions_coverage.lua`'s presence/arity/conformance checks —
passed. The wrong annotation is textually well-formed and declares a
plausible (if false) arity, so nothing in the existing ratchet
distinguishes it from the corrected one.

## Non-goals (for whoever picks this up)

- This capture does not itself propose the fix's shape — whether the
  right mechanism is a runtime-value spot-check for known slots, a
  stricter cross-reference against each binding's C-level push
  sequence per-branch, or something else is an open design question
  for that item's own spec.
- Not a defect in PR #335 or any single binding fix — those diffs are
  correct; this is a gap in the harness meant to guard them.
