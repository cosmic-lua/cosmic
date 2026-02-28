# Documentation and Help

cosmic has embedded documentation searchable from the command line and the REPL.

## Command Line

```bash
cosmic --docs                     # list all documented modules
cosmic --docs json                # look up cosmic.json module
cosmic --docs cosmic.fs           # look up by full module name
cosmic --docs slurp               # search for a symbol
cosmic --help                     # show CLI usage and all options
cosmic --examples                 # list all available examples
cosmic --examples json            # show examples for a module
```

`--docs` searches the embedded documentation index. it supports module names, symbol names, and fuzzy search. if an exact match isn't found, it returns ranked search results.

## REPL

```bash
cosmic -i                         # start interactive REPL
```

inside the REPL:

```lua
help()                            -- list all modules
help("json")                      -- look up a module
help("fs.join")                   -- look up a specific function
```

## Doc Comments

source documentation uses `---` prefix comments:

```teal
--- Brief module description.
--- Longer explanation spanning multiple lines.

--- Create a new widget.
--- @param name string The widget name
--- @param size number The widget size
--- @return Widget The new widget
local function new(name: string, size: number): Widget
```

doc comments are extracted at build time into a serialized index embedded in the binary at `/zip/.docs/index.lua`.

## Generating Documentation

```bash
bin/make docs                     # generate markdown from all sources
bin/make doc-index                # rebuild the embedded doc index
```

`bin/make docs` runs `gendoc.tl` on each source file to produce markdown in `o/docs/`.

## Skill Guides

```bash
cosmic --skill                    # show main skill guide (SKILL.md)
cosmic --skill testing            # testing patterns and commands
cosmic --skill checking           # type checking guide
cosmic --skill formatting         # formatting rules and commands
cosmic --skill makefile           # Makefile patterns and build targets
cosmic --skill modules            # standard library module reference
cosmic --skill docs               # this file — documentation and help
```

## Key Resources

- `AGENTS.md` — complete developer guide (conventions, patterns, error handling)
- `docs/architecture.md` — design decisions, directory structure
- `docs/contributing.md` — setup, workflow, writing modules
- `docs/stdlib.md` — standard library reference
- `docs/build.md` — build system details
