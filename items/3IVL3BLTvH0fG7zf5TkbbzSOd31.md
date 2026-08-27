The closure-carry narrowing rule (3p/tl/tl_patch/closure.tl:33-166,
#1442) keeps a narrow inside a closure iff "the file never reassigns
it" — but for a `global` variable the file is not the assignment
universe: any other module sharing the declaration can assign it at
runtime, so an escaped closure runs on a stale narrow. Probe-confirmed
against the pinned checker (2026-08-27-555873e): `global gv: string |
integer = "x"; if gv is string then local use = function(): string
return gv end end` type-checks clean; another module doing `gv = 2`
then calling `use()` returns an integer typed `string`. For the five
named-function forms this is NEW unsoundness relative to stock tl
(stock widened everything at those boundaries). The tree declares no
globals, so cosmic's own gates never see it — but every user project
cosmic checks inherits the hole, which is exactly the promise-transfer
G3/no-silent-bugs protects. Fix direction: treat a global name as
always-assigned at the widen sites (widen any narrow whose variable
resolves to scope 1), keeping the carry for locals only.
