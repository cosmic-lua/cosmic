# 025 — `test_a_mismatch_is_never_written` asserts a path nothing writes to

severity: low (the code is correct; the property is unasserted)
type: test bug
area: `_make/pin_test.tl`

## issue

the test guarding the central security property — mismatched bytes never
land on disk — asserts `not fs.exists(<root>/3p/blob.bin)`. but since commit
6d6e71c the landing path for fetched bytes is under the build directory:
`o/3p/blob.bin`. the assertion checks a path nothing ever writes to, so it
passes vacuously; a regression that wrote unverified bytes to the real
landing path would not be caught.

(the implementation is correct today: `_make/fetch.tl:95-100` hashes before
`fs.write`. this is purely a test that stopped testing.)

## where

- `_make/pin_test.tl:207` — the stale path in the assertion.
- `_make/fetch.tl:41-47` (`landing`) — where the real path is computed.

## suggested fix

compute the asserted path with the same `landing()` logic (or hardcode the
`o/`-prefixed path) so the test fails if unverified bytes ever land there.
worth also asserting no *partial* file exists (no `.tmp` remnant) after a
mismatch.

## verification

after fixing the path, temporarily invert the write/verify order in
`fetch.tl` and confirm the test fails — proof it guards the property again.
