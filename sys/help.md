cosmic-lua: cosmopolitan lua with bundled libraries

Usage: cosmic-lua [options] [script [args]]

Cosmic options:
  --compile <file.tl>           compile Teal file to Lua, lax mode (stdout)
  --compile-strict <file.tl>    compile with strict type check first; warnings fail
  --include-dir <dir>           add search path for --compile/--check-types (repeatable)
  --format <file>               format Teal or Lua file (stdout)
  --fix <file>                  format Teal or Lua file in place
  --write-if-changed            with --compile/--format and --output: skip write if unchanged
  --check-format <file>         check file formatting (diff on stderr)
  --check-types <file.tl>       type-check a Teal file, strict mode
  --check-style <file.tl>       check style: line length, column width, assert order
  --check-examples <file.tl>    run Example_* functions, check output
  --examples [module]           browse examples (list all, or show module)
  --embed <path>                embed file or directory into executable
  --output <file>               output file for --embed (default: cosmic)
  --extract <dir>               extract zip contents to directory
  --benchmark <file.tl[:pat]>   run Benchmark_* functions, report timing
  --docs [query]                show documentation for module, symbol, or guide
  --test <output> <cmd>...      run test, write <output>.{got,out,err}
                                e.g. cosmic --test o/foo ./cosmic foo_test.tl
  --report <paths>...           report on .got files written by --test
                                e.g. cosmic --report o/foo.got
  --coverage-report <paths>...  merge .cov data, print per-file line coverage
                                e.g. cosmic --coverage-report o/coverage lib
  --make [dir] [target]         generate Makefile, pipe to make -f -
  --skill <dir>                 write agent skill file (SKILL.md) to directory
  --welcome                     show welcome message
  -h, --help                    show this help message

Standard lua options:
  -e <stat>                   execute string 'stat'
  -l <name>                   require library 'name'
  -i                          enter interactive mode
  -v, --version               show version information
  -E                          ignore environment variables
  -W                          turn warnings into errors

Environment variables:
  COSMIC_COVERAGE            directory to dump line-coverage .cov files into
  COSMIC_NO_REQUIRE_HINTS    disable helpful module-not-found suggestions
  COSMIC_NO_WELCOME          suppress welcome message on first run
  COSMIC_FULL_TRACEBACK      show full stack traceback including internal frames

Documentation:
  cosmic --docs [query]      look up docs from the command line
  cosmic --docs guide        list available guides
  cosmic --docs guide.testing  show a specific guide
  cosmic --docs guide.gotchas  common pitfalls (integer vs number, any casts, arg)
  help(<query>)              look up docs in the REPL (interactive only)

Low-level cosmo.* bindings are available but hidden by default.
Use --docs cosmo.<module> to access them directly.

Common patterns:
  proc.is_main()              guard code that runs only as a script (not when required)

For module documentation, use: cosmic-lua --docs [module]
