## Evidence

D23's amended unreachable-nil rule (2026-08, PR #1384) licenses
`assert` on a `cosmo.*` return whose declared `| nil` cannot occur.
Teal's carried `narrow-assert-decl` patch declares `assert` as ONE
return, so `return assert(x, msg)` type-checks as a single-value
return — but at RUNTIME Lua's `assert` returns ALL of its arguments,
so such a function silently becomes two-valued.

Hit while implementing 3IPktATw (PR #1386). `cosmic/fs/path.tl`'s
`join` was written `return assert(joined, "path.join: every argument
was nil")`. `--make ci` passed the checker; the compiled tree then
failed at runtime in `cosmic/fs/find.tl:318`:

```text
bad argument #2 to 'insert' (number expected, got string)
```

because `table.insert(out, join(dir, entry))` expanded to the
three-argument `table.insert`. It broke `o/bin/cosmic` itself — the
built binary could no longer discover its own project root — so the
recovery needed a rebuild from the pin.

The workaround in that PR is a comment: assert as a STATEMENT and
return the local. Nothing checks it. Every future site D23's rule
licenses can repeat the mistake, and the checker will not catch it.

## Why it matters

Two candidate countermeasures, neither picked here:

- a lint beside the planned `-- assert:` checker (board item
  3IQfhI33): flag `return assert(...)` with a message argument in a
  function declaring one return.
- narrow the carried patch so `assert`'s declared arity matches its
  runtime arity in return position, rather than only in expression
  position.

The same trap applies to `check.must`, which AGENTS.md describes with
the same "declares ONE return" language — worth checking whether its
runtime shape agrees.
