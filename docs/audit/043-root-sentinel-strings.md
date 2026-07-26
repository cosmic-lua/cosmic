# 043 — `""` as the root-unit sentinel recurs unnamed across artifact.tl

severity: low
type: design / explicitness
area: `_make/artifact.tl`, `_make/init.tl`

## issue

the empty string means "the project root / the build itself" in at
least five places in `_make/artifact.tl` alone, each re-deriving the
same consequences inline:

- `:221` — `unit == "" and "embed.gen.tl" or fs.join(unit, ...)`
- `:225` — `unit == "" and project.BUILD_DIR or fs.join(project.BUILD_DIR, unit)`
- `:301-302` — `a == "" and "the build" or a` (twice, in the collision
  message; two colliding generated entries read "the build and the
  build")
- `:406` — `binary.dir == "" and project.BUILD_DIR or ...`

`_make/init.tl` has the sibling pattern: `Selection.suffix = ""` means
"no suffix filter", guarded by a comment explaining the `("x"):sub(-0)`
footgun that makes the natural spelling silently match nothing.

none of these is wrong today. the cost is durability: every new call
site must know that `""` is special *and* re-derive what it implies, and
the one that forgets fails silently (the `sub(-0)` comment documents a
near-miss of exactly that). a sentinel that appears more than twice
wants a name; a derivation that appears more than twice wants a
function.

## suggested fix

- name the sentinel once (`local ROOT <const> = ""` in `_make/types.tl`
  or `project.tl`) and add one helper for the dominant derivation:
  `out_dir(unit)` → `BUILD_DIR` or `fs.join(BUILD_DIR, unit)`. the five
  sites collapse to calls, and the collision message gets its label
  from one place (fixing "the build and the build" as a side effect).
- for `Selection.suffix`, make absence explicit: `suffix: string|nil`
  with `nil` meaning unfiltered — the footgun comment then deletes,
  because the type says what the empty string only implied.
