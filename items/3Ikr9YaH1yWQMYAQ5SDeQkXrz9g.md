## Evidence

Found by the fresh-context review of cosmic-lua/cosmic#1616 (item
3IkT88b4, the macroexp frame in `_cli/nilreturn.tl`'s walk). The walk
decides that a body opens by a name-follows tell: `opens_body` treats
`record`/`enum`/`interface` followed by an identifier as a frame
opener anywhere in the token stream, and #1616's `opens_macroexp`
mirrors that shape at `_cli/nilreturn.tl:183` for `macroexp`. So a
plain field access followed by a line that starts with an identifier
opens a frame that never closes — probed on #1616's head `f05bbcd8`:

```teal
local x = t.macroexp
print(x)
```

walks with `residual=1` (one frame left open at end of file), and the
same probe with `t.record`, `t.enum` or `t.interface` leaves the same
residual on the base. The committed tree carries no such access (the
balance gate in `_build/nil_returns_test.tl` is green), so this is the
day-it-lands class again, one level up from #1608 and #1616: the tell
is context-free where tl's grammar is not. tl accepts `macroexp NAME`
only directly after `local`/`global`, and a nested `record NAME` only
at statement start inside a record body, so the previous token decides
in every case. Re-measure at pull time with the probe above through
`_cli/nilreturn.tl`'s walk (the test corpus in
`_build/nil_returns_test.tl` shows how a fixture is fed).

## Change

`_cli/nilreturn.tl`: make the name-follows tells exact by the previous
token — `macroexp NAME` opens a frame only after `local`/`global` (or
as a record field's `= macroexp(`), and `record`/`enum`/`interface
NAME` only where tl accepts a nested declaration (statement position
inside a `record`/`interface` body, or after `local`/`global` at module
scope). Add the probe above, for all four words, to
`_build/nil_returns_test.tl`'s corpus as a file that must balance, and
keep every existing corpus file balancing. Baseline unmoved.

## Non-goals

- No change to `_cli/returns.tl`'s lint or the shared grammar.
- No change to what the walk counts as a lying return.
