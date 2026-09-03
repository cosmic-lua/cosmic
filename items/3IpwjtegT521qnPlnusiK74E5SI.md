## Evidence

Found during review of board item `lNuQ_u063` (definitions.lua:
fallible bindings' `@overload` arms declare `true`, hiding the nil,
err, errno tuple — PR cosmic-lua/cosmopolitan#377).

That PR fixed twelve `@overload` arms that declared a bare `true`
return even though their C entry point routes through the same
`SysretBool`/`SysretInteger` failure path as their primary signature —
a real bug (AGENTS.md: "When slot 1 of a declared return admits nil,
slot 2 is the error — an annotation that deviates is a bug"),
undetected until manually audited.

The review verified no existing test in `tool/lua/test_cosmo.lua` /
`test_definitions_coverage.lua` / `test_definitions_conformance.lua` /
`test_definitions_probes.lua` / `test_definitions_help.lua` actually
guards against this regression class. Reverted one of the twelve fixed
lines (`unix.bind`'s overload) back to bare `true` and reran
`test_definitions_coverage.lua` directly against the built `lua.dbg` —
it still reported PASS. That test's checks 8/9 police syntax and
dialect-banning only, not "does this arm's declared shape match its
primary's fallibility."

## The question

Design and add a check (extending the `test_definitions_coverage`
family, or a new probe) that fails when an `@overload` arm's C entry
point is confirmed fallible (routes through `SysretBool`/
`SysretInteger` or an equivalent failure path) but the arm's declared
return omits the `nil, string?, unix.Errno?` tail its primary carries.
Scope: is this checkable statically from `definitions.lua` + a
per-binding C-source cross-reference, or does it need a per-binding
allowlist the way the coverage ratchet already carries one? Either
way, this closes the gap that let all twelve original sites go
unnoticed and prevents recurrence on a future binding.
