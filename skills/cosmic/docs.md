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
