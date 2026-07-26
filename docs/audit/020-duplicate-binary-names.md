# 020 — duplicate binary names silently overwrite each other

severity: low
type: bug
area: `_make/project.tl`, `_make/validate.tl`

## issue

a project in a directory named `tool` that has both a root `main.tl` (binary
named after the directory) and `cmd/tool/main.tl` (binary named after the
cmd directory) yields two binaries named `tool`. both use the stage
directory `o/stage/tool` and write `o/bin/tool`; the second silently
overwrites the first, and which is "second" follows the build order.

## where

- `_make/project.tl:201-207` — root binary named from the project dirname.
- `_make/project.tl:287-299` — cmd binaries named from `cmd/<name>`.
- no validator rule checks binary-name uniqueness.

## failure scenario

`myapp/main.tl` plus `cmd/myapp/main.tl` (a plausible state mid-refactor
from single- to multi-binary layout): `--make build` reports success, ships
one binary, and which entry it contains depends on iteration order. the
user's "old" binary may be what ships.

## suggested fix

validator rule: collect binary names, refuse duplicates naming both sources
(`make: binary 'tool': declared by both main.tl and cmd/tool/main.tl`).

## test to add

a validator test with the colliding fixture asserting the refusal.
