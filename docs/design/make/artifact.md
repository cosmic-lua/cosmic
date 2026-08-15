# Artifact model

What a build produces: one layout rule, a positive strip floor, and
byte-for-byte reproducibility.

## Layout

Assembled from the **effective tree** — sources overlaid with `o/`
outputs — through one rule:

```
package module, import path P  →  /zip/P.lua
payload under `embed/`         →  /zip/<path inside embed/>
entry                          →  /zip/main.user.lua behind the wrapper
```

The zip root *is* the module root, so "path relative to root = import
path" holds inside the artifact too. `pack_copies` disappears; the
layout is derived, not enumerated.

**Shipping is opt-in**: an artifact carries its modules plus
`embed/**` and nothing else. Every other kind is something you *did*.
With shipping opt-in there is nothing to un-ship, so
`.cosmicignore` stays a purely model-scoped knob and `testdata/`'s
exclusion stops being an exception carved out of a default. Cost: a
`schema.sql` an artifact needs becomes `embed/schema.sql`. Cosmic's own payload lives at
`/zip/cosmic/*`: cosmopolitan's default
`package.path` is `/zip/.lua/`-rooted, so the entry inserts the zip
root ahead of it — behind anything `LUA_PATH` set, or the binary's own
copy shadows an in-tree build. Payload that is *not* modules (the type
tree, `.tl` sources, the docs index) stays dot-prefixed, outside the
module root.

## Stripping

The base is **always stripped to a positive floor**; anything above it
is the project's own files. There is no `--keep`.

**Floor:** compiled `cosmic/**` (the public modules — derived, since
`_` marks the rest), TLS roots, zoneinfo, `.args`.
**Stripped:** the embedded make, `tl.lua`, types, teal-types, cosmic's
`.tl` sources, docs index, guides, `sys/`, `definitions.lua`,
`.lua/cosmo/**`.

This is what lets cosmic build itself with no exception: its artifact
carries `tl.lua`, types, docs, and make because **its own tree provides
them** — from its pins and generators — not because the base kept them.
Any user wanting Teal at runtime vendors it the same way.

A unit that names its own `base` sidesteps this: there is nothing to
strip off a bare runtime. That is the preferred shape for a project
that pins one, and the only shape in which repeated self-builds
converge — `remove` drops zip entries without reclaiming their bytes,
so stripping a cosmic to rebuild a cosmic leaves the old payload behind
as dead space. Sizes and per-generation growth are measured in [payload.md](payload.md).

Risk: a `cosmo.*` binding lazily requiring a stripped `.lua/cosmo/**`
helper. Gate: a **stripped-artifact test lane** running the stdlib's own
tests inside a stripped artifact.

## Reproducibility

Entries carry a fixed mtime (`SOURCE_DATE_EPOCH`, else the DOS floor
315532800) rather than the staging file's. Plumbed through `embed.embed`
and DEFAULTED there, so `--embed` is reproducible too and not only the
`--make` path that passes one explicitly. Gate: build
the same fixture twice into different paths, compare sha256.
