## Change

Secondary id slots refuse the handle. Evidence (review of PR 1518, 2026-08-29, live board): `compare 3IbMHbn1 5yehhrXp` refuses "no item matches" and `compare 3IbMHbn1 «5yeh_hrXp»` refuses "not an id prefix", while the same handle resolves fine as a FIRST argument. Root cause: `_work/gitboard.tl` routes only the first id argument through the `tail.resolve` fallback; PARENT/OTHER/BLOCKER and `new --parent` (measured: lines 198/236/244/252) call `store.resolve` alone, whose `^%w+$` shape check refuses guillemets and dividers. Extract the arg-1 resolve-with-tail-fallback into one helper in `_work/gitboard.tl` and route all five secondary-slot sites through it, so every id-taking position accepts the same forms. Add a test asserting a handle-form PARENT and OTHER resolve (e.g. attach and compare via wrapped handle) and a refusal stays clean for a nonexistent handle.

## Non-goals

No resolver behavior changes inside `_work/store.tl` or `_work/tail.tl` — composition happens at the dispatch layer. Verdict lines, refusal text SHAPES, commit subjects, `flow item=` lines untouched (`_work/flowstats_test.tl` proves the grammars).
