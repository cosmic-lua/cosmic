## Evidence

Found by the fresh-context review of cosmic-lua/cosmopolitan#335
(`unix.tiocgwinsz` annotation fix), by mutation: with the annotation
deliberately malformed as `---@return integer| cols cellular ...` — a
dangling `|` followed by whitespace and then the slot NAME — the
coverage gate's check 9 still PASSED, while cosmic's `_types/gentype.tl`
refused the same text downstream.

Cause, `tool/lua/test_definitions_coverage.lua:695` (at master
`b6b757c9`; 693 at `a358d8b1`): check 9's `parse_union` loop matches the
continuation with `^%s*|%s*[^%s]`, which accepts whitespace after the
`|`, so the token after a dangling bar (here the slot name `cols`) is
consumed as a union member and the malformed type reads as a
well-formed two-member union.

Re-run to confirm (cosmopolitan repo root, `make -j$(nproc)
o//tool/lua/test` built): edit `unix.tiocgwinsz`'s second `@return` in
`tool/net/definitions.lua` (line 7378 at `b6b757c9`) to
`---@return integer| cols ...`, run
`o/tool/lua/lua.dbg tool/lua/test_definitions_coverage.lua`, observe
`test_definitions_coverage: PASS`; restore the file.

**The rule is depth-sensitive, not "no whitespace ever".** Measured by
the first pull of this item: head `definitions.lua` carries two legal
annotations with whitespace around a `|` INSIDE a parenthesized group,
both on `unix.ioctl`:

```
tool/net/definitions.lua:7569  ---@param arg (integer | string)?
tool/net/definitions.lua:7570  ---@return (true|nil | string) result
```

A check that refuses any whitespace after `|` fails the gate on the
unmodified head at exactly those two lines (`unparseable type
expression`). Cosmic's downstream parser accepts them and still refuses
the dangling bar because its tokenizer is depth-aware:
`_types/gentype_parse.tl:13` (`scan_token`) ends the type token at the
first whitespace at bracket depth 0 and treats whitespace inside `()`,
`{}`, `<>` as part of the token, and `valid_type`'s `parse_atom` skips
whitespace before each member. So `integer| cols` tokenizes as the
dangling `integer|` (refused) while `(integer | string)?` is one token
(accepted).

## Change

`tool/lua/test_definitions_coverage.lua`, check 9's `parse_union`:
mirror the downstream rule exactly — at bracket depth 0 of the type
region (outside any `()`, `{}`, `<>`), a `|` must be followed
immediately by a type character; whitespace, end of string, or an
identifier that then reads as the slot name after a depth-0 bar is a
malformed annotation the check reports by binding name, the same way
its other malformations are reported. Inside a bracketed group,
whitespace around `|` stays legal, so the two `unix.ioctl` lines above
keep passing and the gate is green on the unmodified head.

The file has no self-check fixtures for any check today (every check
scans `definitions.lua` only), so add one for this check: inside check
9's `do` block, a small table of known-good and known-bad type strings
run through the same parser entry (`type_ok` or whatever the check
calls), asserting each classification — at least `integer| cols`
(bad), `integer|` (bad), `integer|string` (good), `(integer | string)?`
(good), `(true|nil | string)` (good). That table is the red-before /
green-after demonstration the reviewer holds the diff against.

## Non-goals

- No annotation content changes in `tool/net/definitions.lua`; this is
  the gate only. The two `unix.ioctl` annotations are legal and stay.
- No change to cosmic's `_types/gentype.tl`, which already refuses the
  shape.
