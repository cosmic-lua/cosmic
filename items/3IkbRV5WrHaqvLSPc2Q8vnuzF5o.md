## Evidence

Observed by the builder of cosmic-lua/cosmopolitan#344 (check 9's
depth-0 dangling-bar rule): at depth 0 of a type region the check still
accepts whitespace BEFORE a bar, e.g. `---@return integer |nil rows`,
because `parse_union`'s continuation match keeps its leading `^%s*`.
Downstream, cosmic's `_types/gentype_parse.tl:13` (`scan_token`) ends
the type token at the first depth-0 whitespace, so that annotation
tokenizes as bare `integer` with `|nil rows` read as the start of the
name/description — the declared nil silently disappears from the
generated Teal type. No annotation in head `definitions.lua` has that
shape (the whitespace-around-bar grep at `b6b757c9` found only the two
parenthesized `unix.ioctl` lines), so the gate is green today and the
first such annotation drifts unnoticed. Re-measure at pull time:
`grep -nE '^---@(return|param)[^(]* \|' tool/net/definitions.lua`.

## Change

`tool/lua/test_definitions_coverage.lua`, check 9's `parse_union`: at
depth 0, refuse whitespace before the bar as well as after it (strip
`^|` only, not `^%s*|`, when not `grouped`), mirroring `scan_token`'s
rule that any depth-0 whitespace ends the type. Add `integer |nil rows`
(bad) and `(integer |nil)` (good) to the `TYPE_FIXTURES` table #344
introduced. Gate green on the unmodified `definitions.lua`.

## Non-goals

- No annotation content changes; the gate only.
- No change to cosmic's generator.

Same class, found by #344's review: `fun() : integer` (a space before
the return colon) is accepted by check 9 but `_types/gentype_parse.tl:51`
requires `^:%s*` immediately after the parameter list, so the return
type is dropped downstream. Add `fun() : integer` (bad) and
`fun(): integer` (good) to the same fixture table and refuse the
space-before-colon at depth 0 in the same change.
