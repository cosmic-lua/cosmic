## Change

Measured 2026-08-30 (`_work/gitgraph.tl`): `cmd_new` (line 29) declares
`spec: string` but every internal caller passes nil
(`_work/fixture.tl:99`, `_work/gitgraph_test.tl:50,111,134,136`,
`_work/gitverbs_test.tl:336`); only the CLI layer
(`_work/gitboard.tl:254`) passes a real body. Inside `cmd_new`,
`repo or ""` guards nil while the other same-shaped params do not. And
`cmd_block` carries a full `---`/`@param`/`@return` doc block while
`cmd_new` (line 29) and `cmd_attach` (line 73) carry none. The change,
confined to `_work/gitgraph.tl` (and its tests only if a signature
change requires touching call sites there): make the signatures honest —
pick ONE convention (nil-guard inside like `repo or ""`, or callers
pass `""`) and apply it consistently to every nil-admitted parameter of
`cmd_new`; add doc comments to `cmd_new` and `cmd_attach` in the house
`---`/`@param`/`@return` style, stating purpose and the convention
chosen. No behavior change: existing tests stay green and the type
check (`--check types`, warnings are errors) is the gate.

## Non-goals

No new parameters, no flag changes, no edits to `cmd_block` or any
other verb in the file (qoxdjXJp owns `cmd_block`; TVMAtmvh will later
extend `cmd_new` behavior — keep this diff mechanical so both rebase
cleanly).
