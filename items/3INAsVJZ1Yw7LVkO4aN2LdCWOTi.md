`cosmic.literal` refuses `"a\z` followed by a raw newline, which is
legal Lua that `load` accepts — in the one module whose stated contract
is that its result equals what executing the source would return.

## Evidence

Found 2026-08-24 while building the C parser for the same grammar
(board item 3IKSjEgW), whose test asserts every accepting case against
`load`. This source is the whole case:

```lua
return {s = "a\z
     b"}
```

`load` returns `{s = "ab"}` — that is what `\z` is FOR: it skips the
whitespace that follows it, newlines included. `literal.parse` returns
`nil, "...: unterminated string"`.

The cause is in the lexer, not the escape decoder.
`cosmic/_literal_lex.tl:126-133` scans a short string forward to its
closing quote and refuses on any raw `\n` it passes:

```teal
      while j <= n and src:sub(j, j) ~= c do
        local d = src:sub(j, j)
        if d == "\n" then
          return nil, where .. ":" .. tostring(y) .. ": unterminated string"
        end
        j = j + (d == "\\" and 2 or 1)
      end
```

`\z` is consumed as a two-character pair by the `d == "\\"` step, so the
newline it exists to skip is the very byte that ends the scan.
`escape_at`'s `\z` branch (`cosmic/literal.tl:79-83`) is therefore only
ever reached for whitespace that is not a newline — it is written to
skip newlines and never sees one.

## Why it might matter

The module's own words are that a reader returning different data than
`load` is "the failure this exists to make impossible"
(`cosmic/literal.tl:117-121`). A REFUSAL is the safe half of that — no
caller reads wrong data — so this is a fidelity gap, not corruption,
and nothing in the tree writes `\z` today (`format` never emits it).
What makes it worth a record is that the C parser now reproduces the
refusal ON PURPOSE, to keep the two readers differentially equal, so
the divergence is about to have two implementations instead of one.

## Direction, not a decision

Either fix the lexer (a `\z` may cross a newline; a raw newline still
ends the string otherwise) and fix the C parser in the same breath, or
decide the refusal is the contract and say so where the escape is
documented. The choice matters more than which way it goes: two readers
now have to agree.
