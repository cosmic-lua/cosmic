The casts lint counts a `-- cast:` that appears inside a string
literal, so `_build/casts_baseline.tl` carries a row for a file whose
"casts" are test fixtures. Measured 2026-08-25 against `d3e59de7`:
`_build/casts_test.tl:67` is the string
`"local a = x as {string} -- cast: from any"`, fixture input for the
lint's own test, and it is one of the 192 sites the from-any census
(`docs/design/casts.md`) had to record as not-a-cast. This is the whole
tail of that census — every other site falls into one of the six
classes with its own item. The fix is a scanner that skips string
literals in the check that produces the baseline; the count is off by
one today, and the reason it matters beyond one row is that a lint which
cannot tell code from a quoted example of code miscounts any file that
documents the rule it enforces. The fix must lower the
`_build/casts_test.tl` row in `_build/casts_baseline.tl` — run exactly
the regen command the gate prints and commit the result.
