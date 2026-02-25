cosmic-lua: cosmopolitan lua with bundled libraries

Usage: cosmic-lua [options] [script [args]]

Cosmic options:
  --compile <file.tl>           compile Teal file to Lua, lax mode (stdout)
  --format <file>               format Teal or Lua file (stdout)
  --check-format <file>         check file formatting (diff on stderr)
  --check-types <file.tl>       type-check a Teal file, strict mode
  --check-examples <file.tl>    run Example_* functions, check output
  --examples [module]           browse examples (list all, or show module)
  --embed <path>                embed file or directory into executable
  --output <file>               output file for --compile/--check-format/--check-types/--embed
  --write-if-changed            only write --output file if content differs
  --extract <dir>               extract zip contents to directory
  --benchmark <file.tl[:pat]>   run Benchmark_* functions, report timing
  --docs [query]                show documentation for module or symbol
  --test <output> <cmd>...      run command, write .got/.out/.err
  --report <paths>...           report on test results
  --make [dir] [target]         generate Makefile, pipe to make -f -
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
  COSMIC_NO_REQUIRE_HINTS    disable helpful module-not-found suggestions
  COSMIC_NO_WELCOME          suppress welcome message on first run

Documentation:
  cosmic --docs [query]      look up docs from the command line
  help(<query>)              look up docs in the REPL (interactive only)

Low-level cosmo.* bindings are available but hidden by default.
Use --docs cosmo.<module> to access them directly.

Common patterns:
  proc.is_main()              guard code that runs only as a script (not when required)

For module documentation, use: cosmic-lua --docs [module]
