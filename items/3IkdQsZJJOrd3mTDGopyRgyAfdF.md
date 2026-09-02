## Evidence

Found twice on cosmic-lua/cosmopolitan#342 (localtime doc example), by
its builder and independently by its reviewer, by mutation: deleting
`unix.localtime`'s slot-1 annotation `---@return unix.BrokenDownTime|nil`
(`tool/net/definitions.lua:7259` at `88c054b2`), leaving only the
`string? error` / `unix.Errno? errno` lines, keeps every ratchet in
`tool/lua/test_definitions_coverage.lua` green — coverage, quality and
return-arity all report identical counts. The arity check cannot read
`localtime`/`gmtime`'s arity from the C (they are among the 42 bindings
whose return arity is "not statically readable"), so the only guard on
the success-slot annotation is the conformance probe's observed-slot
pass, which `test_definitions_conformance.lua` runs only for bindings
it probes. The slot-1 `@return` is the line cosmic's `_types/gentype.tl`
reads for the binding's success type, so its silent loss renders the
Teal type as a bare failure tuple. Re-run: delete that line, run
`o/tool/lua/lua.dbg tool/lua/test_definitions_coverage.lua`, observe
PASS; restore.

## Change

`tool/lua/test_definitions_coverage.lua`: add a check that every
`function unix.<name>(...)` (and the other annotated namespaces the
file already walks) whose block carries any `@return` line carries a
FIRST `@return` whose type is not solely `string?`/`unix.Errno?` — a
block whose only return lines are the failure tuple's slots 2 and 3
has lost its success slot and is reported by name. Add the case to the
file's self-check fixtures (#344 introduced `TYPE_FIXTURES`; add a
sibling table for return blocks, or extend the mechanism the file has
at pull time). Mutation shown: with the guard in place, the deletion
above fails naming `unix.localtime`; restored, green.

## Non-goals

- No annotation content change.
- Not a per-slot type check against observed values; that is
  `sTmy_8tBZ`'s class. This is presence of the success slot only.
