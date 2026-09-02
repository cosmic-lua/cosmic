# cosmic docs

every page here is one of four kinds, and its directory says which.
pick the kind by what you need:

| you want | kind | read it as |
|---|---|---|
| to learn by doing | [tutorial/](tutorial/) | `cosmic --docs tutorial.<name>` |
| to get one task done | [howto/](howto/) | `cosmic --docs howto.<name>` |
| a fact | [reference/](reference/) | `cosmic --docs reference.<name>` |
| to understand why | [explanation/](explanation/) | `cosmic --docs explanation.<name>` |

those four directories ship inside the binary. `cosmic --docs howto`
lists the how-to pages, and `cosmic --docs howto.test` prints one.
`cosmic --docs <module>` is the standard library's reference, rendered
from the modules' own doc comments; no page here restates it.

## tutorials

- [quickstart](tutorial/quickstart.md): your first project, from an
  empty directory to a gated fat binary.
- [cli-tool](tutorial/cli-tool.md): a subcommand tool with SQLite
  storage, a test, and a checked example.

## how-to guides

- build and ship: [build](howto/build.md),
  [inspect-artifact](howto/inspect-artifact.md)
- write and check code: [check](howto/check.md),
  [narrow-nil](howto/narrow-nil.md), [type-errors](howto/type-errors.md),
  [format](howto/format.md), [import-modules](howto/import-modules.md)
- test: [test](howto/test.md), [examples](howto/examples.md)
- whole programs: [cli-script](howto/cli-script.md),
  [index-files](howto/index-files.md), [spawn-child](howto/spawn-child.md),
  [serve-http](howto/serve-http.md)
- find things: [find-docs](howto/find-docs.md)

## reference

- [lint](reference/lint.md): every lint rule, its diagnostic, its fix
- [make](reference/make.md): the `--make` verbs, the project model, the
  validator's messages, the environment variables
- [errors](reference/errors.md): the return shapes
- [narrowing](reference/narrowing.md): what narrows a `T | nil`
- [teal](reference/teal.md): the annotations a cosmic user needs
- [conventions](reference/conventions.md): naming, formatting, file length
- [platforms](reference/platforms.md): what differs per OS

## explanation

- [build](explanation/build.md): why there is no build file, why a gate
  verb converges, why shipping is opt-in
- [errors](explanation/errors.md): why the type must admit failure
- [types](explanation/types.md): the two binding layers, and what the
  checker does and does not enforce
- [artifact](explanation/artifact.md): what an executable zip is

## for contributors

[dev/](dev/) holds the same four kinds for people working on cosmic
itself. it does not ship. [goals.md](goals.md) says what cosmic is
trying to be, and [decisions/](decisions/) records what was given up
to get there.
