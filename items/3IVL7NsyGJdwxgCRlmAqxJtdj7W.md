A single-line `local function test_a() ... end test_a()` classifies as
runner mode and the generated tail double-executes the test. The
`called` scan starts at def.ends + 1 (_tool/discover.tl:118) so a
same-line call is never seen as a call, and the reference scan
excludes any token on the definition's own line (t.y ~= c.line,
_tool/discover.tl:142) so the call token is invisible —
referenced_elsewhere stays false, mode = runner, tail appended, the
test runs at load AND via the runner. (`end test_a()` on a later
closing line IS caught as mixed; only the fully one-line shape slips.)
D29's "mixed must never pass" has this one blind spot. fmt would
normalize the shape in this repo's CI, but `--make test` alone and
user projects that skip fmt hit it: a side-effecting test runs twice,
and a failing one reports confusingly. Fix: include the definition
line's tail (tokens after the `end` column) in the reference scan.
