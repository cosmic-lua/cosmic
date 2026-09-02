# Why an artifact is a zip

why a cosmic executable is a zip archive with a program in front of it,
and what follows from that, for a reader who builds or ships one.

## what an executable zip is

a cosmic artifact is a native binary (ELF, Mach-O and PE at once) with a
zip archive appended. Cosmopolitan Libc maps the archive to `/zip/` at
run time, so `io.open("/zip/schema.sql")` reads a member the way it
reads a file. the program in front and the archive behind are one file,
and that one file is the whole distribution: no installation, no
runtime dependency, no unpacking.

the entry point is `/zip/main.lua`. in the cosmic binary it is compiled
from `cmd/cosmic/main.tl`, the same `cmd/<name>/` position `--make`
builds every binary from. `/zip/.args` holds the default command line.

## why the zip root is the module root

a module's import path is its path relative to the project root:
`cosmic/fs.tl` is `require("cosmic.fs")`. inside the artifact the same
rule holds with the zip root in place of the project root, so
`require("cosmic.fs")` resolves to `/zip/cosmic/fs.lua`. one rule
covers build time and run time, and the layout is derived, never
enumerated:

```text
package module, import path P  →  /zip/P.lua
payload at embed/R             →  /zip/R
entry                          →  /zip/main.user.lua behind the wrapper
```

payload that is not a module stays out of the module root by name. the
type tree, the doc index and cosmic's own `.tl` sources are dot-prefixed
(`.types/`, `.docs/`, `.tl/`), so no `require` can reach them and no
member of theirs can shadow a module.

## what an artifact carries

shipping is opt-in. an artifact carries the project's modules and its
`embed/**`, and nothing else. a file that is in the repo is not in the
binary: `docs/`, `testdata/`, tests and `.d.tl` declarations stay
behind without anyone excluding them. a `schema.sql` the program needs
becomes `embed/schema.sql`, and the move is the declaration. what an
artifact contains is greppable from the tree.

the runtime an artifact is built on is stripped to a positive floor,
with no opt-out. what survives is the compiled standard library
(`cosmic/**`), the TLS roots, zoneinfo and `.args`. what goes is the
toolchain: the Teal compiler `tl.lua`, the type declarations, cosmic's
`.tl` sources, the doc index, the guides and the build rules.

so `require("cosmic.json")` works in your artifact and `require("tl")`
does not. an artifact is a program, not a copy of the thing that built
it. a project that wants Teal at run time vendors it, and it ships
because the project's own tree provides it. cosmic's own artifact
carries `tl.lua`, the types and the docs by the same rule: its tree
provides them, through its pins and generators, not because the base
kept them.

the payload is visible in tests too. `--make test` runs tests under a
runner that carries the root `embed/`, so `/zip/R` resolves in a test
exactly as in the artifact.

builds are reproducible. members carry a fixed mtime rather than the
staging file's, so two builds of one tree in two directories are
byte-identical.

## why `proc.interpreter()` and not `arg[0]`

`arg[0]` is the script path as the runtime sees it. when the embedded
entry point dispatched the program, that is `/zip/main.lua`: a member
of the archive, not a path on disk. a child spawned with it fails to
exec, because a Lua file is not a program, and a zip reader handed it
finds a Lua chunk, not an archive.

`arg[-1]` is the interpreter's path, and `proc.interpreter()` returns
it resolved and typed. it is the one name for the running artifact that
is a real file, so it is what a program passes to `child.start` to run
itself, and what it hands to `zipfile` to read itself.

## why an artifact is a queryable database of itself

sqlite ships the `zipfile` virtual table, and `cosmic.sqlite` reaches it
with nothing to install. because the artifact is a valid zip, a `SELECT`
over `zipfile('./o/bin/myapp')` lists its members, sums their sizes and
extracts one as text, with no extraction step and no temporary
directory. `zipfile` is writable too, so `INSERT` adds a member to a
copy and `DELETE` removes one.

the zip format decides the cost of editing. a delete appends a fresh
central directory instead of rewriting the archive, so the file grows
and nothing is reclaimed. the zip stays valid, the program still runs,
and the feature that read the deleted member fails. a smaller artifact
comes from a smaller build, not from a delete.

the modules do not come out readable. every `cosmic/*.lua` member is
precompiled bytecode, so SQL answers what is in an artifact and how big
it is, and `cosmic --docs <module>` answers what a module does.

`cosmic --docs howto.inspect-artifact` has the queries.
`cosmic --docs explanation.build` says why the build that produces an
artifact converges on itself.
