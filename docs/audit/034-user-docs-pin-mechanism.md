# 034 — user-facing docs still document `3p/*/version.lua` pins

severity: medium (user-facing wrongness)
type: docs
area: `docs/build.md`, `docs/architecture.md`, `docs/contributing.md`

## issue

the pin mechanism moved twice — `3p/*/version.lua` (executed Lua) →
`*.pin.tl` read by `cosmic.literal` (3g), with `--make fetch` as the second
reader — but the user-facing docs never followed. they still instruct users
to "create `3p/mylib/version.lua`", describe the fetch flow around it, and
present it as the live mechanism. `3p/` in the tree contains only
`cosmos.pin.tl` and `tl.pin.tl`; no `version.lua` exists anywhere.

this is the largest doc debt found in review because these are the docs a
*user* follows: a reader doing what build.md says today creates a file
nothing reads.

## where

- `docs/build.md:59-64,143` — the versioned-deps walkthrough.
- `docs/architecture.md:108` — the mechanism description.
- `docs/contributing.md:126-138` — the "add a dependency" instructions.
- also: `.github/workflows/pr.yml:19` — a comment referencing
  `3p/*/version.lua` (listed in 033 as well).

## suggested fix

rewrite the three sections around the current mechanism: a `*.pin.tl` is a
single `return { … }` literal (url, version, sha256, optional
`format`/`strip_components`/`platforms`), read as data by `cosmic.literal`
and never executed; fetched bytes land under `o/` mirroring the pin's
position; `--make fetch` (and, until 3i, the Makefile bridge) resolves
them. lift the pin grammar description from `skills/cosmic/make.md`, which
is already accurate, rather than writing it a third time — or better, have
the three docs link one canonical section.

## verification

`grep -rn "version.lua" docs/ .github/` returns only historical mentions in
design logs (which correctly describe it as retired) — no instruction-shaped
hits.
