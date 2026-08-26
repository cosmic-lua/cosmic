`is` against a map/record/array target refuses a `metatable<T>`-typed
value ("can never be"), keeping the cast at `cosmic/fs/types.tl:251`,
though every metatable is a table at runtime and `is {string: any}`
compiles to `type(x) == "table"`. Prototyped 2026-08-26 (research
3ISKgwfn) on a scratch `o/3p/tl/tl.lua`: a `metatable-over-table`
allowance at the two "can never be" fact-eval sites (the branch
warning ~11510 and the error ~11607) — accept the IsFact when the
narrowed type shows as `metatable<...>` and the target's typename is
map/record/array/interface — makes `getmetatable(x) is {string: any}`
check, lets the fs/types.tl site drop both its guard-and-cast lines
for a plain is-guard (`--check types` passed on the rewritten site),
and leaves `mt is integer` refused ("can never be", probed). The
slice: one tl_patch entry pair anchored at those two sites (a real
resolve of the std metatable nominal, not the show_type string match
the scratch used), a narrowing test pinning positive and negative,
and — per the cold-build rule 3ISKgfS6 recorded — the fs/types.tl
cast retire in a SEPARATE follow-up once the pin carries the patch.
