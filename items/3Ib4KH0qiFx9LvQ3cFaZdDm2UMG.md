Evidence, measured 2026-08-29: `cosmic.shape` landed on main ~2026-08-26
("Validate a decoded value into a declared record" — `shape.into` walks
a `literal.parse`/`json.decode` value against a Spec and hands it back
typed); the board machinery predates it (`_work/item.tl` created
2026-08-17) and uses it nowhere (`grep -rn "shape\." _work/*.tl` outside
tests: 0 hits). `item.decode` instead hand-coerces every field —
`grep -c "tostring(t\." _work/item.tl` → 14 — plus tonumber for `pr`,
over the `{string: any}` the literal reader returns. A Spec declared
beside the Item record would delete the coercion wall and leave only the
domain transforms (space-joined id lists, `problems()` rules); the same
boundary exists where `_work/gh.tl` reads GitHub JSON. This is the
pattern shape's own doc names as its reason to exist.
