# 049 — pin grammar: url-derived output naming and the dual sha spelling

severity: low (design; both halves already flagged as anomalies in the design's own record)
type: design / feature
area: docs/design/make.md units; `_make/pin.tl`

## observation

two places where the pin concept cuts against the design's own grain:

1. **output naming comes from the url tail**, not from position — the
   one ⚠ in the units table, recorded as a falsified prediction of the
   "output path derives from position" rule. it is also the reason
   url-name *validation* has to exist at all (a query string, `..`, or
   `%` in the tail reaching `fs.join` — the fix pass added the guard),
   and it couples the on-disk landing name to a remote server's path
   layout: bump a pin to a url whose tail is spelled differently and
   every consumer of the landing path (`embed.gen.tl` reads
   `o/3p/tl/tl.lua`, `o/3p/cosmos/{lua,make}`) is chasing a name the
   project never chose.

2. **two spellings of integrity**: flat `sha` and the `platforms`
   table, which exist so one committed file can satisfy both pin
   readers (180b0d3 says so). a pin that must be written twice can
   disagree with itself — the exact drift class pins exist to prevent —
   and the grammar carries the workaround permanently unless it is
   retired with the second reader.

## proposal

- **name the output positionally or explicitly**: default the landing
  name from the pin's own name plus the format's extension
  (`3p/tl/tl.pin.tl` + `tar.gz` → `o/3p/tl/tl.tar.gz`), with an
  optional `output` field for the cases where the archive's inner
  layout makes the name matter. the url becomes purely *where the
  bytes come from*; position stays the manifest; the name-validation
  problem disappears rather than being guarded.
- **retire one sha spelling** when 030 lands one shared reader: pick
  `platforms` (with `*` as the single-platform case) or flat-`sha`
  (with `platforms` as the multi case), document the survivor in the
  pin grammar, and have the reader refuse the other with a pointer.
  close the units-table ⚠ in the same change — the table row becomes
  true again, which is worth a line in the log.
