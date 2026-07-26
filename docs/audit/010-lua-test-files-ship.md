# 010 — `*_test.lua` / `*_example.lua` classify as modules and ship

severity: medium
type: bug
area: `_make/project.tl`

## issue

the test/example suffix classification matches only `.tl` files. in a
Lua-only project — a supported shape, pinned by the `luaonly` fixture —
`foo_test.lua` is classified as kind `module`: it is never run by
`--make test`, and it is embedded into the released binary. the design's
"`.lua` sources are first-class" (make.md line ~138) silently does not
extend to the test/example markers.

## where

- `_make/project.tl:177-180` — suffix checks are `%_test%.tl$` /
  `%_example%.tl$` only; `.lua` files fall through to `module`.

## failure scenario

a user ports a Lua project: `db_test.lua` sits beside `db.lua`.
`--make test` reports the project has no tests (or runs none of these),
`--make build` ships the test file inside `o/bin/<name>`, and nothing
diagnoses either. tests silently not running is the worse half.

## suggested fix

decide and enforce, either way:

1. **first-class (preferred):** classify `*_test.lua` / `*_example.lua` as
   `test` / `example`, run them under the same testrun contract (they are
   plain Lua; the runner already executes compiled `.lua`).
2. **unsupported:** refuse them in the validator with a message telling the
   user tests must be `.tl` — a loud trap instead of a silent one.

## test to add

extend the `luaonly` fixture with a `main_test.lua`; assert it runs under
`--make test` (option 1) or is refused by `check` (option 2), and in either
case that it is not embedded in the artifact.
