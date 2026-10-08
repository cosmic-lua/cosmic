# cosmic

cosmic is a runtime for self-contained command-line software: one file
holds the language, the compiler, the standard library, and the build.
Programs it builds ship the same way, one executable, carrying a
database of compiled modules rather than reading files at run time.

## build

```text
bin/zig build boot
```

`boot` builds the cores and stages generated files outside the checkout,
under `$XDG_CACHE_HOME/cosmic/trees` (`$HOME/.cache/cosmic/trees` by default),
in a directory keyed by the canonical project root. Set
`COSMIC_BUILD_HOME=/absolute/base` to choose another base outside the project; each worktree
keeps its own directory there. Existing `o/` output is unused.

## run a file

```sh
echo 'print("hello from the database")' > hello.tl
bin/cosmic hello.tl
```

```output
hello from the database
```

## learn more

cosmic's code is Teal, typed Lua: see [teal-language.org](https://teal-language.org).
The tool documents itself, in a release binary too:

- `cosmic help` lists every verb, and `cosmic help <verb>` describes one.
- `cosmic docs` lists the standard library and the guides, and
  `cosmic docs <name or words>` shows one or searches them all.
- `cosmic docs quickstart` is a tour of the standard library, and
  `cosmic docs project` builds a first project: its files, tests,
  program, and the verbs that run them. Their sources are
  [doc/guides/quickstart.md](doc/guides/quickstart.md) and
  [doc/guides/project.md](doc/guides/project.md).

## design

what cosmic is for and how it is built lives in
[doc/design.md](doc/design.md); how this documentation works, and what
its examples promise, is [doc/meta.md](doc/meta.md).
