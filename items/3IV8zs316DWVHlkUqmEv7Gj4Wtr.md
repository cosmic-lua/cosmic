## Goal

`cosmo.DecodeLua` refuses a `\z` that crosses a newline, which `load`
accepts: `return {a = "x\z\ny"}` is legal Lua reading as `{a = "xy"}` —
skipping the whitespace that follows, newlines included, is what `\z`
is FOR. The C reader's short-string scan stops its skip at `'\n'` on
purpose, with a comment saying the divergence is deliberate, because it
was written to mirror the Teal reader in whilp/cosmic, which refused it
too.

That reader no longer refuses it. whilp/cosmic#1436 landed the fix
(board item `3INAsVJZ1Yw7LVkO4aN2LdCWOTi`, accepted), and this is that
item's step 2 — its `## Change` scoped both halves and only the cosmic
half was carried to a verdict. Until this lands, the two implementations
of the literal grammar are differentially unequal on a case the sibling
harness can reach, and the C engine's refusal falls through to the Teal
lexer for every spanning string.

## Change

`tool/net/llua.c`, the `esc == 'z'` branch of the short-string scan:
drop the `*q != '\n'` stop so the skip walks every following whitespace
byte, and rewrite the comment that made the divergence deliberate. A raw
newline not behind `\z` still ends the string, via the check at the top
of the scan. `tool/lua/test_llua.lua` pins both directions.

Carried by whilp/cosmopolitan#283 (2 files, +13/-7, head `c9583448`),
which is written, green, and open.

## Non-goals

No other escape changes; no long-string changes; no scan restructure.
No binding contract shape changes — `DecodeLua`'s signature and error
channel stand — so no `definitions.lua` change, and no type regen or
wrapper fix on the cosmic side.

## Acceptance

`make -j$(nproc) o//tool/lua/test` PASS with the updated case, on
whilp/cosmopolitan#283's head. `origin/master:tool/net/llua.c` no longer
carries `&& *q != '\n'` in the `esc == 'z'` branch. Landing reaches
cosmic through the next cosmos pin bump, where the engine corpus's
spanning-string case then agrees under both engines rather than by
fall-through.

## Enablement

None. The cosmic half is already on `main` and the dispatch in
`literal.tl` makes the order free: a C refusal falls through to the Teal
lexer for the answer, so behavior is correct today and merely faster
once this lands. The item exists because the board had no view over this
half — `3INAsVJZ` reached `completed` while step 2 was still an open PR,
and no item carried `pr = 283`.
