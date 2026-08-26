Research: the three remaining checker gaps, enumerated and designed —
deliverable is evidence and follow-up slices, not code. (1)
**or-fallback residue**: the carried `narrow-or-fallback` entry
already narrows `x or fallback` when the fallback cannot be nil, yet
three casts in `_cli/build/init_test.tl` (`:72`, `:144`, `:169`,
measured 2026-08-26 at `b4ad036b`) still say "or fallback does not
narrow" — read each site, name which shape escapes the patch (a
nil-admitting fallback, both-union operands, value-position vs
if-position), and decide patch-extension vs truer reason. (2)
**closure carry-through**: narrowing is dropped at every closure
boundary even for locals never reassigned after the guard (probed
during the casts sweeps; the guard-then-typed-local idiom in
`cosmic/coverage/init.tl` and `_tool/benchmark.tl` exists only for
this). Design question: can the checker prove non-reassignment cheaply
enough to carry narrowed facts into closures soundly? Find where tl
resets facts at function entry and what the patch would anchor on;
prototype on a scratch build the way the strict-nil census did. (3)
**metatable<any>**: `is` refuses map/record tests against the
`metatable<T>` nominal ("can never be"), keeping one cast in
`cosmic/fs/types.tl`. Decide whether an is-test against a table-kinded
target should accept metatable-typed values (they are tables at
runtime). Output: one capture per decided follow-up with the anchored
find/replace sketch and probe transcript, filed under the parent;
this item's spec updated with the summary; finish per review.md's
research clause.
