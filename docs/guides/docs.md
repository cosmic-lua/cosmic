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

a symbol's page also lists where the shipped guides and other modules' docs
mention it, ranked by relevance — so a guide that drifted from a function's
contract costs one screen to notice, not a grep across `docs/guides/`:

```
$ cosmic --docs cosmic.fs.read
### read
...
Mentioned in:
  guide.checking § Type Annotations   line 164  local text = fs.read("/etc/hostname") or ""
  guide.recipes § CLI script skeleton line 25   local data, read_err = fs.read(path as ...
```

each line names the guide (or module) and heading it comes from, the line
number, and a snippet of the mention.

## REPL

```bash
cosmic -i                         # start interactive REPL
```

inside the REPL:

```text
help() -- list all modules
help("json") -- look up a module
help("fs.join") -- look up a specific function
```
