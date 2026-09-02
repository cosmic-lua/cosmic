# Find documentation

steps for looking up a module, a function, an example, or a prose page from the
binary, for a reader at the command line or in the REPL.

## look up a module or a symbol

`--docs` searches the documentation index embedded in the binary. it takes a module
name, a full module path, or a symbol.

```bash
cosmic --docs              # list every documented module
cosmic --docs json         # one module, by short name
cosmic --docs cosmic.fs    # one module, by full name
cosmic --docs fs.join      # one function
```

when no entry matches exactly, `--docs` searches. a query with several matches prints
ranked results with their kinds. a query with none prints the nearest names under
`Did you mean?`, with a `Try:` line naming the closest.

```bash
cosmic --docs join         # ranked search results
cosmic --docs slurp        # no match: suggestions
```

the low-level `cosmo.*` bindings are hidden from the module list. reach one by its
full name.

```bash
cosmic --docs cosmo.unix
```

## read the examples

`--examples` prints a module's `Example_*` functions with the output each one prints.

```bash
cosmic --examples          # every module with examples
cosmic --examples json     # one module's examples
```

## read the CLI usage

`--help` prints every option, every environment variable cosmic reads, and the
module list.

```bash
cosmic --help
```

## look up docs in the REPL

start the REPL and call `help`. it takes the same queries as `--docs`.

```bash
cosmic -i
```

```text
help()          -- list every module
help("json")    -- one module
help("fs.join") -- one function
```

## read a prose page

the prose pages are four kinds. ask by what you need.

| you want | command |
|---|---|
| to learn by doing | `cosmic --docs tutorial` |
| steps for one task | `cosmic --docs howto` |
| a fact | `cosmic --docs reference` |
| to understand why | `cosmic --docs explanation` |

each of those lists the kind's pages. read one by its address, `<kind>.<name>`.

```bash
cosmic --docs howto              # list the how-to pages
cosmic --docs howto.test         # one page
cosmic --docs reference.lint     # a reference page
```
