## Goal

No silent bugs, coverage-floor family: verify or fix the one
normalize() branch that still parses a different text than the one
its attribution names.

## Evidence

d592567 (2026-08-18) fixed _tool/coverage/report.tl's /zip branch
returning the raw chunk name as the static-analysis parse target —
the parse silently failed and totals collapsed to hits-only for 22+
days. The sibling branch at _tool/coverage/report.tl:129 (the
`o/*.lua` staged-copy case) still returns `return source, p`: it
attributes coverage to the repo `.tl` while parsing the staged
compiled `.lua` for executable lines. Unlike the fixed branch the
parse target exists on disk, so nothing fails silently in the same
way — but the executable-line set is computed from a DIFFERENT text
than the one the rows name, which is correct only if tl's compiled
output is line-stable against its source for every construct the
analyzer counts. Nothing asserts that.

## Direction

Small: a test that compiles a .tl containing the known line-shifting
shapes (multi-line function heads, long conditionals, inline records)
and asserts the parse-target line set matches the .tl's own — then
either document the branch as verified line-stable, or return
`source, source` there as d592567 did for /zip. The open
coverage-floor issues (#1215, #1228, #1103) are adjacent; whoever
takes one should take this look with it.
