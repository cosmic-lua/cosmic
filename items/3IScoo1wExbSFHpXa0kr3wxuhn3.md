## Evidence

`cosmic --check fmt` mis-indents every line after an `if` whose
condition carries a `function` type, and the mangled shape is a
FIXPOINT — so the gate does not merely reformat the code, it enforces
the wrong indentation and rejects the right one.

Measured 2026-08-26 at main `186c4689`, with `o/bin/cosmic` built from
that tree.

Input (`probe.tl`), correctly indented by hand:

```teal
local function probe(v: any): string
  if v is function(): any then
    return "fn"
  end
  return "other"
end
return {probe = probe}
```

- `o/bin/cosmic --check fmt probe.tl` FAILS on the correct source:
  `have:     return "fn"  (whitespace differs)` /
  `want:   return "fn"  (whitespace differs)`.
- `o/bin/cosmic --format probe.tl` emits the `if` body at the WRONG
  depth and never recovers — `return "fn"` lands at 2 spaces (the
  `if`'s own depth) and `end` / `return "other"` / the closing `end`
  all land at column 0:

```teal
local function probe(v: any): string
  if v is function(): any then
  return "fn"
end
return "other"
end
return {probe = probe}
```

- `o/bin/cosmic --fix probe.tl` writes that shape, and
  `--check fmt` on the result PASSES. The mangled form is the
  formatter's fixpoint, so nothing ever converges back.

The `function` keyword in TYPE position is read as opening a block,
so the emit walk's depth accounting is off by one from that line to
the end of the file.

This is the same class as 3IP9ijhv, where `call-after-define`'s
`end_line_of` miscounts a `function` keyword in type position — one
bug per consumer of the same faulty assumption, in two different
walks.

## Why it matters

The shape `if x is function(...) then` is the natural Teal guard for a
dynamically looked-up function, and it is unwritable today: the gate
demands the broken indentation. PR #1415 hit exactly this and had to
route around it with `type(version_fn) == "function"` plus two casts,
where one `is` guard would have done. Every future site that wants to
narrow to a function type pays the same tax, and a reader of the
committed result sees indentation that lies about the block structure.

## Suspected fix

Wherever the formatter's depth walk sees `function`, it must
distinguish the statement/expression form (opens a block, needs an
`end`) from the type form (`function(A): B`, closes with `)` and opens
nothing). The type form appears after `is`, after `:` in a
declaration, inside an `as` cast, and in a record field type.
Worth checking whether the two walks (formatter emit and
`end_line_of`) can share one predicate rather than each growing its
own.
