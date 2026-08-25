G3 — close the **binding boundary** class of `from any` casts: 13 of
the tree's 192, measured 2026-08-25 against `d3e59de7` and mapped in
`docs/design/casts.md`. A `cosmo.*` or Lua-stdlib call has its return
typed `any` by the generated declarations, or returns an untyped tuple
the caller types slot by slot (`cosmic/signal.tl:259` types three slots
of one `sigaction` return; `cosmic/url.tl:64` casts `cosmo.ParseParams`
to `{{string}}`; `cosmic/errno.tl:52` looks an `E*` constant up by name
off the `unix` table). The files and their site counts:
cosmic/coverage/init.tl (3), cosmic/errno.tl (1), cosmic/fd.tl (1),
cosmic/quicksand/proc.tl (1), cosmic/signal.tl (3), cosmic/teal.tl (1),
cosmic/url.tl (2), cosmic/zip.tl (1). Nothing in this repository closes
these: `_types/gentype.tl` generates the declarations from
`tool/net/definitions.lua` in `whilp/cosmopolitan`, so a binding
annotated with its concrete return type is what makes the cast
disappear. The work is therefore a change in the other repository —
carry `--repo whilp/cosmopolitan` on the slice — landed on its own,
followed by a pin bump and the cast removals here. AGENTS.md freezes the
C boundary's return shapes, so this is an annotation change, never a
contract change. The follow-up diff here must lower the affected rows in
`_build/casts_baseline.tl` — run exactly the regen command the gate
prints and commit the result.
