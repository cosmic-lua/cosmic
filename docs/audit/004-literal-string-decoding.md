# 004 — `cosmic.literal` returns wrong string values

severity: high (public API returns silently wrong data)
type: bug
area: `cosmic/literal.tl`

## issue

string tokens are unwrapped with `tk:sub(2, -2)`, which assumes every string
token is delimited by exactly one character on each side. two consequences:

1. **escape sequences are not decoded.** `"a\nb"` yields the four characters
   `a`, `\`, `n`, `b` — not the three-character string with a newline. any
   pin or config whose value uses `\n`, `\t`, `\"`, `\\`, `\ddd`, or `\u{...}`
   gets a silently different value than Lua evaluation of the same file
   would produce.
2. **long strings are mangled.** `[==[hello]==]` yields `==[hello]==` —
   only one delimiter character is stripped from each end.

both were verified empirically against the branch binary. the same
`sub(2, -2)` applies to `["..."]` keys, so bracketed keys with escapes are
wrong too.

## where

- `cosmic/literal.tl:53` — bracketed string key: `toks[i + 1].tk:sub(2, -2)`.
- `cosmic/literal.tl:73` — string value: `v.tk:sub(2, -2)`.

## why it matters

the module's contract is "the literal a file returns" — read as data, equal
to what executing the file would return. today's two committed pins use only
plain urls and hex digests, so nothing in-tree trips it; the first pin with
an escaped character (or a downstream user of the public module) gets
corrupted data with no error.

related: negative numbers are refused — `n = -1` is a parse error ("found
'-'") because the tokenizer emits `-` as its own token. if intentional,
document it; pins and configs plausibly want negative numbers, so accepting
a `-` prefix before a number token is probably right.

## suggested fix

decode string tokens properly: detect the delimiter (`"`, `'`, `[=*[`), strip
the matching pair, and for short strings decode Lua escape sequences (a
small explicit decoder — do not use `load`, which the module exists to
avoid). for long strings, strip the level-matched brackets and the optional
leading newline, no escape processing (matching Lua semantics). accept an
optional leading `-` on number tokens.

## test to add

round-trip tests in `cosmic/literal` tests: escaped short strings
(`"\n"`, `"\""`, `"\\"`, `"\u{263A}"`), long strings at levels 0–2, a
bracketed escaped key, and `n = -1`. assert equality with the value the
equivalent Lua chunk returns (computed inline in the test, not via load of
the fixture).
