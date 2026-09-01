## Evidence

Found by the fresh-context review of cosmic-lua/cosmopolitan#335
(`unix.tiocgwinsz` annotation fix), by mutation: with the annotation
deliberately malformed as `---@return integer| cols cellular ...` — a
dangling `|` followed by whitespace and then the slot NAME — the
coverage gate's check 9 still PASSED, while cosmic's `_types/gentype.tl`
refused the same text downstream.

Cause, `tool/lua/test_definitions_coverage.lua:693` (line at head
`a358d8b1`): check 9's `parse_union` loop matches the continuation with
`^%s*|%s*[^%s]`, which accepts whitespace after the `|`, so the token
after a dangling bar (here the slot name `cols`) is consumed as a union
member and the malformed type reads as a well-formed two-member union.

Re-run to confirm (cosmopolitan repo root, `make -j$(nproc)
o//tool/lua/lua` built): edit `unix.tiocgwinsz`'s second `@return` in
`tool/net/definitions.lua` to `---@return integer| cols ...`, run
`make -j$(nproc) o//tool/lua/test`, observe check 9 pass; restore the file.

## Change

`tool/lua/test_definitions_coverage.lua`, check 9's `parse_union`:
refuse a `|` that is not followed by a type token — a union member must
start immediately (no whitespace) with a type character, and a bar
followed by whitespace, end of string, or an identifier that then reads
as the slot name is a malformed annotation the check reports by
binding name, the same way its other malformations are reported. Add
the dangling-bar case to the check's own negative fixtures (whatever
form the file already uses for a known-bad annotation) so the gate is
shown red on the malformation before the fix and green after.

## Non-goals

- No annotation content changes in `tool/net/definitions.lua`; this is
  the gate only.
- No change to cosmic's `_types/gentype.tl`, which already refuses the
  shape.
