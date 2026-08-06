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
                                  lint      file length, casts, test order
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
  -c <line>                     run one recipe line as argv, not shell
                                (for make: SHELL := cosmic. the closed
                                 vocabulary: assert-elf, assert-marker,
                                 capture, compile, copy, exec, link,
                                 record, remove, tee, verdict, write-list)
  --make <verb> [paths]...      build this project
                                (build, check, test, fmt, lint, example,
                                 benchmark, docs, coverage, run, ci, fetch,
                                 clean; `--make help` lists them)
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
  COSMIC_FENCE               0 opts out of the derived build sandbox (on by default)
  COSMIC_JOBS                build parallelism (default: one job per cpu)
  COSMIC_MAKE_ROOT           name the project root instead of using the cwd
  COSMIC_VERSION             the --version stamp, when no .version is committed
  COSMIC_COVERAGE            directory to dump line-coverage .cov files into
  COSMIC_INSTRUMENTATION     1 emits timing spans to stderr
  COSMIC_LOG_LEVEL           cosmic.log's threshold
  COSMIC_NO_REQUIRE_HINTS    disable helpful module-not-found suggestions
  COSMIC_NO_WELCOME          suppress welcome message on first run
  COSMIC_FULL_TRACEBACK      show full stack traceback including internal frames

  Every other COSMIC_-prefixed variable is INTERNAL: the build sets it
  for its own children (which engine, what a step may exec, the
  converge budget, a test's scratch directory). Setting one by hand
  confuses a build rather than configuring it.

  NO_COLOR, TERM, TMPDIR, HOME, PATH, XDG_*, SOURCE_DATE_EPOCH and CI
  are third-party conventions cosmic honours rather than invents.

Documentation:
  cosmic --docs [query]      look up docs from the command line
  cosmic --docs guide        list available guides
  cosmic --docs guide.testing  show a specific guide
  cosmic --docs guide.gotchas  common pitfalls (integer vs number, any casts, arg)
  cosmic --docs guide.lint   every lint rule, its failure and its fix
  help(<query>)              look up docs in the REPL (interactive only)

Low-level cosmo.* bindings are available but hidden by default.
Use --docs cosmo.<module> to access them directly.

Common patterns:
  proc.is_main()              guard code that runs only as a script (not when required)

For module documentation, use: cosmic-lua --docs [module]
