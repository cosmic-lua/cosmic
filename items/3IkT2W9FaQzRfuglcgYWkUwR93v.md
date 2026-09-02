## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#339. #321 changed
`unix.gmtime`/`unix.localtime` to return one `unix.BrokenDownTime`
table and updated their `@return` annotations in
`tool/net/definitions.lua`, but the doc-comment prose above
`unix.localtime` (around line 7210 at `25aebd9c`) still shows the
pre-#321 positional REPL example:

```
2022    4       28 …  "PDT"
```

The annotations (what cosmic's `_types/gentype.tl` reads) are correct;
only the example teaches the old shape. Re-locate with
`grep -n 'function unix.localtime' tool/net/definitions.lua` and read
the comment block above it.

## Change

`tool/net/definitions.lua`, the `unix.localtime` (and, if it carries
one, `unix.gmtime`) doc-comment example: replace the positional row
with the table the binding returns now, matching the example
`tool/net/help.txt` carries after #339. No annotation change; the
coverage ratchet must stay green (`make -j$(nproc) o//tool/lua/test`).

## Non-goals

- No change to the `@return` annotations or the C.
