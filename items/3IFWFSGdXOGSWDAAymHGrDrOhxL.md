## Evidence

`cosmic/quicksand/proxy/rules.tl:50` declares

```
local function parse_rule(key: string): string, integer
```

and returns `nil` in slot 2 on three of its four paths — that is its
documented contract ("A missing port, `:*`, or `:` all mean 'any
port'", `:43-45`). `match` at `:174` takes the same value as
`port: integer` and reads a nil port as "no port constraint"
(`entry[port] or entry["*"]`, and `s.port == nil or s.port == port`).
The module record repeats the lie at `:212`.

So a deliberate, documented nil rides in a slot typed non-nilable,
in both directions, in the proxy's allowlist enforcement path. The
honest spelling is `string, integer | nil` on `parse_rule` and its
record entry, and `port: integer | nil` on `match` — this is a tuple
whose second element is genuinely optional, not a fallible return, so
D20 rule 11 (a fallible return has TWO slots) does not apply and
nothing about the error shape changes.

Found on 2026-08-22 while refining `3I9Tko2h`, whose slice fixes the
adjacent nil-port defect in `cosmic/quicksand/proxy/http.tl` and
explicitly walls this off as out of scope. The two are file-disjoint,
so they can land in either order.

Worth checking in the same pass: whether `--check types` accepts the
honest signatures without touching `rules.tl`'s callers, since Teal
admits nil into every non-index position (measured in `3I9Tko2h`).

**Attach under `3HyRcW05`** (the cast/typing epic), sibling of
`3I9Tko2h`.
