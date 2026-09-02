# The artifact model

what a build produces: one layout rule, a positive strip floor and
byte-for-byte reproducibility, for a contributor who changes staging,
the floor or the embed step.

## layout

the artifact is assembled from the effective tree, the sources
overlaid with `o/` outputs, through one rule:

```text
package module, import path P  ->  /zip/P.lua
payload at embed/R             ->  /zip/R
entry                          ->  /zip/main.user.lua behind the wrapper
```

the zip root is the module root, so "path relative to the root =
import path" holds inside the artifact too. the layout is derived, not
enumerated. the generated `/zip/main.lua` wrapper prepends
`/zip/?.lua;/zip/?/init.lua` to `package.path` and installs the cosmic
searcher, then loads `/zip/main.user.lua`. Cosmopolitan's own default
path is `/zip/.lua/`-rooted, which is why the wrapper inserts the zip
root ahead of it. an artifact answers for itself: the prepend is
unconditional, so `LUA_PATH` cannot reach ahead of `/zip`.

**shipping is opt-in.** an artifact carries its modules plus `embed/**`
and nothing else. every other kind of file is something you did to the
project, not something the artifact needs. with shipping opt-in there
is nothing to un-ship, so `.cosmicignore` is a model-scoped knob and
`testdata/`'s exclusion is not an exception carved out of a default.
the cost: a `schema.sql` an artifact needs is `embed/schema.sql`.
cosmic's own modules live at `/zip/cosmic/*`. payload that is not
modules (the type tree, `.tl` sources, the docs index) stays
dot-prefixed, outside the module root.

modules are staged as source and compiled to bytecode on the base
runtime that loads them. the bytecode keeps its debug info, so line
coverage still counts a module a test only reaches through the built
artifact. the chunk name is the `/zip/` path the module lands at,
never a filesystem path, so two builds dump identical bytes.

## stripping

the base is always stripped to a positive floor. anything above it is
the project's own files. there is no `--keep`.

the floor keeps compiled `cosmic/**`, `cosmic.lua` (the `cosmic`
module itself, which flattens to the zip root), `usr/` (TLS roots and
zoneinfo), `.args` and `.cosmo`. it is a keep-list rather than a strip
list on purpose: a base that grows a directory does not silently start
shipping it in every artifact anyone builds.
`cosmic/embed/floor_test.tl` verifies the list. everything else a
cosmic base carries goes: the embedded make, `tl.lua`, the type tree,
cosmic's `.tl` sources, the docs index, `sys/` and `definitions.lua`.

this is what lets cosmic build itself with no exception. its artifact
carries `tl.lua`, the types, the docs and make because its own tree
provides them, from its pins and generators, not because the base kept
them. a project that wants Teal at runtime vendors it the same way.

a namespace the project claims leaves the floor. the validator lets a
project define `cosmic/**` when it defines the whole namespace, and
the embed step drops the base's copy for each claimed namespace, so
the artifact ships one standard library instead of the project's
winning on `package.path` while the base's rides along underneath.

a unit that names its own `base` sidesteps stripping: there is nothing
to strip off a bare runtime. that is the preferred shape for a project
that pins one, and the only shape in which repeated self-builds
converge. removing a zip entry does not reclaim its bytes, so
stripping a cosmic to rebuild a cosmic leaves the old payload behind
as dead space. [payload.md](payload.md) has the sizes.

`testdata/` never appears in an artifact; the `assets` fixture in
`_make/testdata/` builds and runs that claim.

## reproducibility

every entry carries a fixed mtime: `SOURCE_DATE_EPOCH` when the
environment sets it, else 315532800, the DOS floor a zip entry can
represent (1980-01-01). the floor is both the safe default and a
visibly synthetic one. the value is defaulted inside `cosmic.embed`,
so `--embed` is reproducible too and not only the `--make` path.

two gates hold the claim. `_make/artifact_test.tl`'s
`test_reproducible` builds a fixture twice and compares. CI's `repro`
lane refetches the real pins in a fresh container, rebuilds at another
path and byte-compares against the `build` lane's artifact. varying
the tree path, not only the output directory, is what catches an
absolute path or a stray build note riding into the binary.
