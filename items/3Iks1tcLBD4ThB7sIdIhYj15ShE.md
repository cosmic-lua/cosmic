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

## Change

`tool/lua/test_definitions_coverage.lua`, check 9: refuse the three
shapes at depth 0 — `?` must follow `)` directly, a typed vararg's
colon must be flush (`...:`), and a depth-0 fun return list admits no
comma (a multi-value return is written as `---@return` lines, the way
every existing annotation does). Add each bad shape and its good twin
(`fun()?: integer`, `fun(): ...: string`, `fun(): boolean`) to
`TYPE_FIXTURES`. Gate green on the unmodified `definitions.lua`.

## Non-goals

- No annotation content changes; the gate only.
- No change to cosmic's generator.
