## Evidence

Found by the fresh-context review of cosmic-lua/cosmic#1608 (the
frame-balance gate over `_cli/nilreturn.tl`'s walk): a module-scope
Teal macro expression

```teal
local macroexp m(x: integer): integer
  return x
end
```

walks with underflow 1 — `skip_declaration_head` consumes `macroexp` as
a name, so no frame opens and the body's `end` arrives on an empty
stack. The committed tree carries no `macroexp` (`grep -rn 'macroexp'
--include=*.tl . | grep -v '^./o/'` returns nothing at #1608's head
`006062b3`), so the tree-wide balance test in `_build/nil_returns_test.tl`
is green today and fires the day one lands. That is the gate working;
the fix belongs in the walk before it does.

## Change

`_cli/nilreturn.tl`: treat `macroexp` where `function` is treated in
the declaration head — it opens a body frame whose declared return is
parsed the same way, and it can lie about nil exactly like a function.
Add a fixture case to `_build/nil_returns_test.tl`'s corpus (a
module-scope `local macroexp` and a `record` method `macroexp`) that
must balance, and one lying macroexp whose `return nil` is counted.
Baseline unmoved (no committed site).

## Non-goals

- No change to the `fallible-returns` lint in `_cli/returns.tl` unless
  the shared grammar is what mis-reads the head; if so, say so in the
  PR and keep the fix in the shared function.
