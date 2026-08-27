The closure-carry narrow rule landed under `3IVL3BLT` also fires at the
LOOP sites, which is correct but undescribed and unpinned by any test.

The patch entry's anchor sits inside `widen_all_unions`, which
`while`, `repeat`, `forin` and `fornum` all reach with their own node
(`o/3p/tl/tl.lua:13173, 13241, 13262, 13317`). So a global narrow now
drops at loop entry, not only at closure entry. Measured against the
patched build:

    -- inside a guard that has already narrowed the global g to string
    for _i = 1, 3 do print(g:upper()) end

    before: Type check passed
    after:  cannot index key 'upper' ... of type string | integer

The soundness argument is the same one the entry was written for — a
loop body can run after another module assigns the global, exactly as a
closure body can — and the direction is conservative, so this behaviour
is right. Straight-line use is unaffected, so the common idiom survives
and the tree needed no edits.

What is missing is that nothing says so. The entry's comment describes
closures only, and the three tests added with it pin closures only. A
later reader hitting the loop diagnostic has no way to tell whether it
is intended behaviour or a regression, and nothing would catch it if a
future patch revision silently dropped the loop half while keeping the
closure half green.

Two things close it: a line in the patch entry's comment naming the loop
sites as in-scope for the rule, and a fourth test pinning the loop case
so the guarantee is real rather than incidental. Both are small and
belong together.
