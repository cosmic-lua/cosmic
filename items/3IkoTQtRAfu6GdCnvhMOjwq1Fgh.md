## Evidence

Reported by the builder of cosmic-lua/cosmic#1616 (item 3IkT88b4, the
nilreturn walk's macroexp frame). `_cli/returns.tl`,
`check_fallible_returns`, iterates only tokens with `t.tk == "function"
and t.kind == "keyword"`, so a Teal macro expression's signature is
never read by the `fallible-returns` lint: at #1616's head `f05bbcd8`,

```teal
local macroexp f(): T | nil, string, integer
  return nil, "x", 1
end
```

declares three slots past the error and passes `bin/cosmic --check
lint` clean, where the same signature on `local function f()` is
diagnosed. Same root cause #1616 fixed in the walk (`macroexp` is an
identifier, not a keyword, so a keyword scan skips it); #1616's
Non-goals kept the lint unchanged because the shared head grammar reads
the head correctly — the miss is the lint's own token filter. The
committed tree carries no `macroexp` (`grep -rn 'macroexp'
--include=*.tl . | grep -v '^./o/'`), so the gate is green today and
silent the day one lands. Re-measure at pull time with the snippet
above in a scratch `.tl` under `_cli/`.

## Change

`_cli/returns.tl`: extend the fallible-returns scan to a `macroexp`
identifier that opens a body (the same tell #1616 uses in
`_cli/nilreturn.tl`: `macroexp` followed by a name, or `= macroexp(`
in a record field), reading its declared return list through the
shared grammar. Add a case to the lint's test corpus: a macroexp with
three slots past the error is diagnosed at its line; a two-slot
macroexp and `local macroexp = 1` are not.

## Non-goals

- No change to `_cli/nilreturn.tl` (landed in #1616).
- No change to D20 rule 11's shape; the rule is unchanged, only its
  reach.
