`is`-fact narrowing is dropped at every closure boundary: probed
2026-08-26 (research 3ISKgwfn) — `raw is function(any)` guarded, then
`raw(1)` inside a `local function` → "not a function: <any type>" —
which is the gap the guard-then-typed-local idiom in
`cosmic/coverage/init.tl:104-106` and `_tool/benchmark.tl` works
around. The machinery for a sound fix exists:
`TypeChecker:widen_all_unions(node)` (tl.lua ~10911) already widens
only names `assigned_anywhere(name, node)` when given a node, and the
closure-boundary reset is exactly the node-LESS calls at the
function-definition sites (assignment-of-function-rvalue ~13073,
local_function ~13586, local_macroexp ~13619, global_function ~13648).
Passing the closure's OWN node is proven unsound by probe: it keeps a
narrow that a later enclosing-scope reassignment invalidates. The
sound scope is the nearest enclosing function body, and scopes carry
no nodes (`begin_scope` stores only {vars = {}}), so the patch needs a
tracked current-body stack (~15 lines) plus the node argument at the
four sites. The slice: that patch entry, probes for the sound case,
the reassignment case (must refuse), and the coverage-idiom shape;
the idiom retires in a separate follow-up once the pin carries it.
