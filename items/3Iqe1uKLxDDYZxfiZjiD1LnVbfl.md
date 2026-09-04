## Finding

An anonymous function literal passed directly as an argument does not
get its declared multi-value return type checked against the
parameter's function-type signature under `--check types` (strict),
even when the literal's own `return` statements match that signature
value-for-value. Pulling the same body out into a named function with
an explicit return-type annotation, and passing that function by name
instead, checks cleanly.

## Repro

Verified against the `cosmic-lua/cosmic` prerelease
`2026-09-02-c60dcf1` (`cosmos 2026.08.31-6dfa6728a, Lua 5.5`),
downloaded and sha256-verified from
https://github.com/cosmic-lua/cosmic/releases/tag/2026-09-02-c60dcf1.

`cosmic.sqlite`'s `Database.transaction` is declared:

```teal
transaction: function(self: Database, fn: function(Database): boolean, string): boolean, string
```

Minimal fail case:

```teal
local sqlite = require("cosmic.sqlite")
local db = assert(sqlite.open(":memory:"))
local ok1 = assert(db:transaction(function(tx)
  return true, ""
end))
print(ok1)
assert(db:close())
```

```
$ ./cosmic-lua repro.tl
cosmic-lua: repro.tl:3:46: error: argument 1: incompatible number of returns: got 1 (<unknown type>...), expected 2 (boolean, string)
```

The callback body already returns two values (`true, ""`); the error
persists whether the second value is `""` or `nil`. Only the arity —
not the value types — is ever satisfied by an inline literal in this
position in the tested build.

Pulling the identical body into a named function with an explicit
return-type annotation, and passing the function by name, checks and
runs cleanly:

```teal
local function transfer(tx: sqlite.Database): boolean, string
  return true, ""
end
local ok1 = assert(db:transaction(transfer))
print(ok1)  -- true
```

## Scope of the finding

Not yet localized to a specific checker pass or file — could be a
narrowing gap in the pinned `tl` (upstream or `3p/tl/tl_patch`), or
specific to how `cosmic.sqlite`'s `TxFn`/`Database.transaction`
signature is declared. Needs investigation before a `## Change`
section can be written:

- does the same minimal repro fail against a bare `function(T): boolean, string`
  parameter with no cosmic.sqlite involved (isolate from the sqlite
  module entirely)?
- is this arity-inference gap specific to a two-value return type, or
  does a single-value return function-type parameter also reject an
  inline literal?
- where does the checker path diverge between a named function value
  and an inline literal at the same call-site position — is arity
  inferred from the literal's own body at all, or only compared
  post-hoc against a placeholder type?

## Why it matters for G3

`db:transaction`/`db:savepoint`'s documented usage pattern in
`cosmic --docs cosmic.sqlite` is exactly the inline-lambda form this
repro shows failing — the doc's own snippets, if written verbatim, hit
the type error the wrapper's contract should permit. Under G3 ("every
type is checked, none asserted... narrowing and soundness gaps closed
upstream-first") this is a soundness/completeness gap in the checker's
handling of a documented, everyday callback pattern, not a cast or an
escape hatch — but it currently forces users into an undocumented
workaround (name the function, annotate its return type explicitly)
to use a documented API as shown.
