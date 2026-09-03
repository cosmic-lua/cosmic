## Evidence

A builder adding `_make/seed.tl` needed one new `.cosmic-coverage` row.
The refusal at `_make/policy.tl:178-184` says to hand-edit the row but
gives no number for a file that has none, and names the bypass in the
same breath ("run this from the recording environment with
`COSMIC_COVERAGE_ENV=1` set"). The builder ran
`COSMIC_COVERAGE_ENV=1 o/bin/cosmic --make coverage --baseline`
locally (4 transcript hits), saw 173 rows move from environment noise,
reverted them by hand and kept the one row — exactly what CLAUDE.md
says a developer machine never should do, one env var away.

## Change

`_make/policy.tl` (or the coverage stage that renders the ratchet):
after a passing or failing `--make coverage`, for every measured file
with no row in `.cosmic-coverage`, print one line in the file's own
row syntax, e.g. `  ["_make/seed.tl"] = {covered = 40, total = 49},`,
under a header "new files, rows to add by hand". The refusal text at
:178-184 then says "a new file's row is printed by a plain `--make
coverage`; paste it" and drops the sentence that names the env var
(the recording lane sets it for itself and needs no prompt).

`_make/policy_test.tl`: a fixture with one unlisted file asserts the
printed row; the refusal text assertion updates.

## Non-goals

No change to the ratchet's pass/fail, no automatic edit of
`.cosmic-coverage`.
