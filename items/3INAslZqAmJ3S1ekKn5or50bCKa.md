Two of `parse_table`'s refusal messages in `cosmic/literal.tl` are
unreachable: the lexer's `$EOF$` sentinel gets there first, so no input
can produce them.

## Evidence

Found 2026-08-24 while enumerating the reader's refusal classes for the
C parser (board item 3IKSjEgW). `cosmic/_literal_lex.tl:150` appends a
sentinel token to every stream:

```teal
  toks[#toks + 1] = {tk = "$EOF$", kind = "eof", y = y}
```

so `parse_table`'s `while i <= n` always has a token to look at, and
running out of input lands on the token-shaped refusals rather than the
end-of-input ones:

- `cosmic/literal.tl:311` — `unterminated table in <noun>`, the loop's
  fall-through. Unreachable: the sentinel is at index `n`, so the loop
  body always runs and either returns or refuses.
- `cosmic/literal.tl:233` — `unexpected end of <noun>`, guarded by
  `if not v`. Unreachable for the same reason: `toks[i]` after a key is
  at worst the sentinel, which is not nil.

Measured against the tree at `585d17f9`, with a binary built from it:

```
literal.parse("return {")    -> literal:1: a literal is a table of `name = <literal>` entries; found '$EOF$'
literal.parse("return {a")   -> literal:1: a literal is a table of `name = <literal>` entries; found 'a'
literal.parse("return {a =") -> literal:1: a literal holds literals only; found '$EOF$' (no variables, calls or concatenation)
```

Neither dead message appears for any truncation. (`"return {a"`
complains about `a` rather than the sentinel because an identifier not
followed by `=` fails the key test before the sentinel is ever read —
the same class, one token earlier.)

## Why it might matter

Small, but it is two of the reader's refusal classes — a third of the
end-of-input surface — that no test can cover and no fuzz run can
reach, sitting in a module whose refusals are its contract. It also
misleads: a reader enumerating the classes (as the C parser's spec did)
counts seventeen where fifteen exist.

## Direction, not a decision

Delete both branches, or make the messages reachable by refusing at the
sentinel with them instead of with the `found '$EOF$'` wording — the
second reads better to a user, since `$EOF$` is an internal spelling
leaking into a message. Whichever way, `--make coverage` should stop
carrying two unreachable lines.
