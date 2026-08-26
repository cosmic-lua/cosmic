`cosmic.literal.format` writes a value nested 33 tables deep that
`cosmic.literal.parse` then refuses to read back. Both layouts do it, and
`format`'s own guard is supposed to prevent exactly this.

`render_table` (`cosmic/_literal_format.tl`) refuses at `depth >
MAX_DEPTH`, so it stops at 33. But when a table's values are all scalars
it is spelled by `render_inline` instead, and `render_inline` has NO
depth check — so the innermost table of a 33-deep value slips past the
guard and is written. `parse` has the same `MAX_DEPTH` and refuses it.

Observed at main `7e8e1170` (the shape predates the pin bump on branch
`3IRqU7yQ-literal-compact`; both layouts behave identically here because
the compact layout hands this value to the pin layout):

```text
d=32 leaf=true   pin=ok   roundtrip=parse-ok
d=33 leaf=true   pin=ok   roundtrip=PARSE-FAIL literal:33: a literal nests deeper than 32 tables
d=33 leaf=false  pin=ok   roundtrip=PARSE-FAIL literal:33: a literal nests deeper than 32 tables
d=34 leaf=true   pin=REFUSED ...: nests deeper than 32 tables
```

Reproduce by building a table nested `d` levels with `cur.a = next` and a
scalar in the innermost, then `literal.format(v)` and `literal.parse` on
the result.

This is the writer's one promise broken — what `format` writes, `parse`
reads back — for one shape, silently: the caller gets a string and finds
out at read time. `cosmic/_literal_format_test.tl` pins the boundary at
32 and at 34 but not at 33, which is why it has stayed invisible.

The fix is a depth check in `render_inline`, or refusing the inline
spelling at `MAX_DEPTH`; either way the boundary tests should gain the
33-deep case in both layouts.
