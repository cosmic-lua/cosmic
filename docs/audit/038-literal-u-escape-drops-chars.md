# 038 — `cosmic.literal` `\u{}` escape swallows the next two characters

severity: high (silently wrong data; regression introduced by 4a15b92)
type: bug
area: `cosmic/literal.tl`

## issue

the escape decoder added in 4a15b92 (fixing audit 004) has an off-by-two
in the `\u{…}` branch. `escape_at` finds the escape with

```
local hex, after = s:match("^{(%x+)}()", i + 2)
```

a lua position capture is **absolute** — `after` is already the index just
past the closing `}`, regardless of the `init` argument — but the code
returns `(after as integer) + 2`, treating it as if it were relative to
the match start. the decode loop resumes two characters too far, so every
`\u{…}` escape silently swallows the two characters that follow it.

verified empirically against the merged module (bootstrap cosmic,
compiled `cosmic/literal.tl`):

```
of_source([[return { s = "\u{41}BC" }]])   → "A"      (want "ABC")
of_source([[return { s = "\u{41}BCDE" }]]) → "ADE"    (want "ABCDE")
of_source([[return { s = "x\u{263A}y" }]]) → "x☺"     (want "x☺y")
```

`string_value` is also used for `["…"]` bracketed keys, so keys are
affected the same way. this is the exact failure class 004 was about —
silently wrong values from the module whose contract is "equal to what
executing the file would return" — reintroduced by its fix.

## why the new test missed it

`cosmic/literal_test.tl:38` covers exactly one `\u` case: a lone
`"\u{263A}"` with nothing after it. at end-of-string the overshoot only
skips past `#body`, ending the loop — the one position where the bug is
invisible. every other escape branch computes its return index
arithmetically (`i + 2`, `i + 4`, `i + 1 + #digits`) and is correct; `\u`
is the only branch that used a position capture.

## where

- `cosmic/literal.tl` — `escape_at`, the `c == "u"` branch:
  `return utf8.char(...), (after as integer) + 2`.

## fix

return `after` unmodified — it is already the absolute next index:

```
return utf8.char(tonumber(hex, 16) as integer), after as integer
```

## test to add

extend `literal_test.tl` so every escape form is followed by trailing
text, which pins the return-index arithmetic of each branch, not only the
decoded value: `"\u{41}BC"` == `"ABC"`, `"\x41BC"`, `"\65BC"`, `"\zBC"`
(with leading whitespace), and a bracketed key `["\u{41}k"]`. the
lone-escape-at-end shape is the one blind spot this bug proved.
