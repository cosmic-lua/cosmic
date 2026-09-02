## Evidence

Found by the fresh-context review of cosmic-lua/cosmopolitan#346
(item 3IkbRV5W, check 9's depth-0 whitespace rules), probing check 9's
grammar in `tool/lua/test_definitions_coverage.lua` against cosmic's
`_types/gentype_parse.tl` (origin/main, 2026-09-02). Three shapes the
gate still accepts that the generator misreads, each the same class
#344 and #346 closed for bars and return colons:

1. `fun() ?: integer` — accepted; gentype's `split_type_desc` reads
   the optional marker only when `?` follows `)` directly, so both the
   `?` and the return type fall into the description.
2. `fun(): ... : string` — a space before the typed vararg's inner
   colon is accepted; gentype's `^(%.%.%.:%s*[^%s]+)` needs the colon
   flush, so the return type falls into the description. Head carries
   3 typed-vararg returns (`definitions.lua:985,1191,1342`), all
   flush.
3. `fun(): boolean, string` — a depth-0 fun return list with a comma
   is accepted by `parse_labeled_typelist`, while gentype's
   `scan_token` ends the return at `boolean,`.

Zero lines of any shape in head `definitions.lua`, so the gate is
green today and the first such annotation drifts unnoticed. Re-measure
at pull time: inject each shape into a scratch copy of
`definitions.lua` and run the test (`make -j$(nproc) o//tool/lua/test`
or the script under `o//tool/lua/lua`); all three currently pass.

Bounce, measured 2026-09-02 by the builder on origin/master `ea7558bd`:
the comma rule cannot apply to `---@overload` lines. Head carries six
overloads whose depth-0 return list has a comma (`definitions.lua:1908,
1909, 1910, 5586, 6289` and one more), e.g. `---@overload fun(...):
zip.Writer?, string?`, and check 9 scans `@overload` regions through
the same `parse_fun` → `parse_labeled_typelist` path as the other
tags; a one-token comma refusal there turns the gate red on the
untouched file (7 failures, all `@overload`, none on `@param`/
`@return`/`@field`/`@type`). Those are not generator misreads:
`_types/gentype_parse.tl` reads an overload's return list whole via
`^%-%-%-@overload%s+fun%b()%s*:%s*(.+)$`, never through `scan_token`,
so the comma is the only spelling of a multi-value overload return.
The other two shapes are unaffected and have no head occurrences.

## Change

`tool/lua/test_definitions_coverage.lua`, check 9: refuse the three
shapes at depth 0 — `?` must follow `)` directly, a typed vararg's
colon must be flush (`...:`), and a depth-0 fun return list admits no
comma — with the comma rule SCOPED to the tags whose type token
gentype ends at whitespace (`@param`, `@return`, `@field`, `@type`); an
`@overload` line keeps its comma-separated return list, which gentype
reads whole. Add each bad shape and its good twin (`fun()?: integer`,
`fun(): ...: string`, `fun(): boolean`) to `TYPE_FIXTURES`, plus one
overload twin (`---@overload fun(): zip.Writer?, string?` accepted) so
the scope is pinned by a fixture. Gate green on the unmodified
`definitions.lua`.

## Non-goals

- No annotation content changes; the gate only.
- No change to cosmic's generator.
- Not the one-line multi-return `---@return T name, self` form
  (`definitions.lua:931, 985, 1320, 1334, 1342`), where the comma
  follows the slot NAME; whether gentype reads its second value is
  unmeasured and is its own item if it does not.
