cosmic-lua: cosmopolitan lua with bundled libraries

Usage: cosmic-lua [options] [script [args]]

Cosmic options:
  --compile <file.tl>           compile Teal file to Lua, lax mode (stdout)
  --compile-strict <file.tl>    compile with strict type check first; warnings fail
  --include-dir <dir>           add search path for --compile/--check types (repeatable)
  --modules <manifest>          resolve requires against a project's build closure
  --format <file>               format Teal or Lua file (stdout)
  --fix <file>                  format Teal or Lua file in place
  --write-if-changed            with --compile/--format and --output: skip write if unchanged
  --check <kind> <file>         run one gate check on one file. kinds:
                                  types     type-check, strict
                                  fmt       formatting (diff on stderr)
                                  lint      every lint rule (--docs guide.lint)
                                  example   run Example_* and check output
                                a kind IS its verb: the whole project is
                                `--make check|fmt|lint|example`
  --examples [module]           browse examples (list all, or show module)
  --embed <path>                embed file or directory into executable
  --output <file>               output file for --embed (default: cosmic)
  --extract <dir>               extract zip contents to directory
  --exe <path>                  with --embed/--extract: operate on <path>, not this exe
  --benchmark <file.tl[:pat]>   run Benchmark_* functions, report timing
  --docs [query]                show documentation for module, symbol, or guide
  --test <output> <cmd>...      run test, write <output>.{got,out,err}
                                e.g. cosmic --test o/foo ./cosmic foo_test.tl
  --report <paths>...           report on .got files written by --test
                                e.g. cosmic --report o/foo.got
  --coverage-report <paths>...  merge .cov data, print per-file line coverage
                                e.g. cosmic --coverage-report o/.coverage cosmic
  -c, --recipe <line>           run one recipe line as argv, not shell
                                (for make: SHELL := cosmic. the closed
{{recipe_verbs}}
  --make <verb> [paths]...      build this project
{{make_verbs}}
  --welcome                     show welcome message
  -h, --help                    show this help message

Standard lua options (each also has a long spelling):
  -e, --execute <stat>        execute string 'stat'
  -l, --load <name>           require library 'name'
  -i, --interactive           enter interactive mode
  -v, --version               show version information
  -E, --ignore-env            ignore environment variables
  -W, --warn                  turn warnings into errors

Environment variables:
{{env_vars}}

  Every other COSMIC_-prefixed variable is INTERNAL: the build sets it
  for its own children, and the registry (`_cli/env_vars.tl`) declares
  each one — a gate fails when code and registry disagree. Setting an
  internal one by hand confuses a build rather than configuring it.

  NO_COLOR, TERM, TMPDIR, HOME, PATH, XDG_*, SOURCE_DATE_EPOCH and CI
  are third-party conventions cosmic honours rather than invents.

Documentation:
  cosmic --docs [query]      look up docs from the command line
  cosmic --docs guide        list available guides
  cosmic --docs guide.quickstart  your first project, end to end
  cosmic --docs guide.testing  show a specific guide
  cosmic --docs guide.gotchas  common pitfalls (integer vs number, any casts, arg)
  cosmic --docs guide.lint   every lint rule, its failure and its fix
  help(<query>)              look up docs in the REPL (interactive only)

Low-level cosmo.* bindings are available but hidden by default.
Use --docs cosmo.<module> to access them directly.

Common patterns:
  proc.is_main()              guard code that runs only as a script (not when required)

For module documentation, use: cosmic-lua --docs [module]
