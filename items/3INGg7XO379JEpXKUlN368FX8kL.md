`cosmic.literal` promises a value "equal to what executing the file
would return". Inside a long bracket string it is not: Lua's lexer
normalizes line endings, and neither reader does.

Found while reviewing whilp/cosmopolitan#274 (board `3IKSjEgW`, the C
parser). The C parser matches the Teal reader on every case below, so
this is not that item's bug — it is a divergence both readers share
against real Lua, and it is why #274's byte sweep over long brackets
skips byte 13 (`tool/lua/test_llua.lua`, `test_every_byte_in_a_long_bracket`)
with the inline comment "a lone \r is line-ending translation, not
data". It IS data to both readers, which is the divergence.

Measured against a `lua.dbg` built from whilp/cosmopolitan
`2435c594` (the PR head), each source decoded by `cosmo.DecodeLua`
and by `load`:

```
CR in long bracket       load=x\10y      decode=x\13y      DIFFER
CRLF in long bracket     load=x\10y      decode=x\13\10y   DIFFER
LFCR in long bracket     load=x\10y      decode=x\10\13y   DIFFER
CR right after opener    load=x          decode=\13x       DIFFER
CRLF right after opener  load=x          decode=\13\10x    DIFFER
CR in long comment       load=1          decode=1          agree
```

Lua's rule (`third_party/lua/llex.c`, `read_long_string` /
`inclinenumber`): any of `\n`, `\r`, `\n\r`, `\r\n` inside a long
string becomes a single `\n`, and one such sequence immediately after
the opening delimiter is dropped. The Teal reader
(`cosmic/literal.tl`, `string_value`'s long-bracket branch) takes the
raw body and drops a leading `"\n"` only; the C parser
(`tool/net/llua.c`, `ScanLongString`) does the same, deliberately, to
stay differentially equal to it.

Why it matters beyond tidiness: `3p/tl/tl_patch.tl` carries 22 level-5
long brackets and is read by `_make/patch.tl` on every build. A
checkout with CRLF endings (a `core.autocrlf` clone, an editor that
converts) would feed both readers `\r\n` where Lua sees `\n`, so the
patch text a build applies would differ from the patch text Lua would
produce — silently, since neither reader refuses it.

The fix is one change in two places, and it must land in both readers
at once or the differential harness (`3IKSjS8N`) will report the
disagreement it just created: normalize `\r\n`, `\n\r`, `\r` and `\n`
to `\n` while copying a long bracket's body, and drop one such
sequence after the opener rather than a bare `"\n"`. Then #274's byte
sweep stops needing its byte-13 exclusion, which is the acceptance
signal.

Sibling of `3INAsVJZ` (`\z` across a newline), the other place both
readers agree with each other and not with Lua.
