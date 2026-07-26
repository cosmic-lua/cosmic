-- cosmic-lua dispatcher: entry point for the cosmic binary, which
-- handles special args and dispatches to features.

global warn: function(...: any)

-- The zip root IS the module root (3d): the payload sits at /zip/cosmic/**
-- while cosmopolitan's default path is /zip/.lua/-rooted. Inserted ahead of
-- that default but BEHIND anything LUA_PATH set -- prepending outright would
-- shadow an in-tree build with the binary's own copy, which is #666's shape.
local at = package.path:find("/zip/.lua/", 1, true) or 1
package.path = package.path:sub(1, at - 1) ..
"/zip/?.lua;/zip/?/init.lua;" .. package.path:sub(at)

-- cosmic-owned runtime .tl searcher (#669): resolves and compiles .tl
-- modules through cosmic.teal, fails the require() on compile errors,
-- and caches compiled output. See cosmic.searcher for the details.
require("cosmic.searcher").install()
if not os.getenv("COSMIC_NO_REQUIRE_HINTS") then
  require("_cli.require_hints").install()
end

local getopt = require("cosmic.getopt")
local cli_args = require("_cli.args")
local help = require("_cli.help")
local handlers = require("_cli.main_handlers")

-- Parsed options record
local record Options
  execute: {string}
  load: {string}
  interactive: boolean
  version: boolean
  warnings: boolean
  help: boolean
  script: string
  script_args: {integer: string}
  compile: string
  compile_strict: string
  format: string
  fix: string
  --- The kind named by `--check <kind>`, and the file it applies to.
  check_kind: string
  check_file: string
  embed: {string}
  output: string
  extract: string
  exe: string
  examples: string
  benchmark: string
  docs: string
  welcome: boolean
  test_argv: {string}
  test_output: string
  report_paths: {string}
  coverage_report_paths: {string}
  build_mode: string
  build_argv: {string}
  recipe: string
  make_verb: string
  make_argv: {string}
  skill: string
  write_if_changed: boolean
  include_dirs: {string}
  error: string
end

-- Parse arguments using cosmo.getopt iterator API
local function parse_args(): Options
  -- Absent record fields read as nil; only the accumulating and
  -- boolean fields need initial values.
  local opts: Options = {
    execute = {},
    load = {},
    interactive = false,
    version = false,
    warnings = false,
    help = false,
    script_args = {},
    embed = {},
    welcome = false,
    write_if_changed = false,
    include_dirs = {},
  }

  local shortopts = cli_args.shortopts
  local longopts: {getopt.LongOpt} = cli_args.longopts
  local short_needs_arg = cli_args.short_needs_arg
  local long_needs_arg = cli_args.long_needs_arg

  -- Options that consume all remaining arguments (no script after them)
  local long_greedy: {string: boolean} = {
    ["report"] = true,
    ["coverage-report"] = true,
  }

  -- Options that take their own argument AND one positional after it:
  -- `--check <kind> <file>`. Without this the file reads as a script
  -- name and parsing stops before it.
  local long_extra_arg: {string: boolean} = {
    ["check"] = true,
  }

  -- Find first non-option argument (script name) to know where to stop parsing
  local script_idx: integer = nil
  -- --build and --test are followed by a FOREIGN argv — the child's own
  -- flags. getopt permutes, so it would eat those as cosmic options;
  -- slice the payload off and parse only to the option's own argument.
  -- --test lacked this (#801): its child ran bare, hit the REPL and
  -- exited 0, so teal and format reported passes without ever running.
  local payload: {string} = nil
  local payload_parse_end: integer = nil
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--" then
      script_idx = i + 1
      break
    elseif a:sub(1, 2) == "--" then
      local opt_name = a:sub(3)
      -- --make joins them (#2a): `--make <verb> [paths…]` is a verb plus
      -- a path list, and a path is a positional getopt would permute
      -- into its own option parse.
      if opt_name == "build" or opt_name == "test" or opt_name == "make" then
        payload = {}
        -- a `--` here defends against that same bug; step over it
        local from = arg[i + 2] == "--" and i + 3 or i + 2
        for k = from, #arg do
          payload[#payload + 1] = arg[k]
        end
        payload_parse_end = i + 1
        script_idx = nil
        break
      elseif long_greedy[opt_name] then
        script_idx = nil
        break
      elseif long_extra_arg[opt_name] then
        i = i + 3
      elseif not opt_name:find("=") and long_needs_arg[opt_name] then
        i = i + 2
      else
        i = i + 1
      end
    elseif a:sub(1, 1) == "-" and #a > 1 then
      if #a == 2 and short_needs_arg[a:sub(2, 2)] then
        i = i + 2
      else
        i = i + 1
      end
    else
      script_idx = i
      break
    end
  end

  -- Only parse cosmic options (before script name)
  local cosmic_args: {string} = {}
  if script_idx then
    for k = 1, script_idx - 1 do
      if arg[k] ~= "--" then
        cosmic_args[#cosmic_args + 1] = arg[k]
      end
    end
  elseif payload_parse_end then
    for k = 1, math.min(payload_parse_end, #arg) do
      cosmic_args[#cosmic_args + 1] = arg[k]
    end
  else
    cosmic_args = arg
  end

  local rename_err = cli_args.renamed_check(cosmic_args)
  if rename_err then
    opts.error = rename_err
    return opts
  end

  local r0, perr = getopt.parse(cosmic_args, shortopts, longopts)
  if not r0 then
    opts.error = "cosmic-lua: " .. (perr or "failed to parse arguments")
    return opts
  end
  local r = r0 as getopt.Result -- cast: record union after guard

  -- A required argument that's absent lands in `missing` (named without
  -- dashes). Give a targeted usage hint where we have one, else a generic
  -- "requires an argument" message.
  if #r.missing > 0 then
    local m = r.missing[1]
    if m == "test" then
      opts.error = "cosmic-lua: --test requires: --test <output> <cmd>...\nSee: cosmic-lua --help"
    elseif m == "build" then
      opts.error = "cosmic-lua: --build requires: --build <mode> <args>...\nSee: cosmic-lua --help"
    elseif m == "make" then
      opts.error = "cosmic-lua: --make requires: --make <verb> [paths...]\nSee: cosmic-lua --help"
    elseif m == "embed" then
      opts.error = "cosmic-lua: --embed requires: --embed <path>\nSee: cosmic-lua --help"
    elseif m == "output" then
      opts.error = "cosmic-lua: --output requires: --output <file>\nSee: cosmic-lua --help"
    else
      local dash = #m == 1 and "-" or "--"
      opts.error = "cosmic-lua: option '" .. dash .. m ..
      "' requires an argument\nSee: cosmic-lua --help"
    end
    return opts
  end

  -- Truly unrecognized options (already spelled with their dashes).
  if #r.unknown > 0 then
    opts.error = "cosmic-lua: unknown option '" .. r.unknown[1] .. "'"
    return opts
  end

  -- Global modifiers are collected before the dispatch loop so they are
  -- honored regardless of position (`--extract dir --exe app`).
  for _, o in ipairs(r.opts) do
    if o.opt == "exe" then
      opts.exe = o.arg
    end
  end

  for _, o in ipairs(r.opts) do
    local opt = o.opt
    local optarg = o.arg

    if opt == "c" then
      opts.recipe = optarg
      return opts
    elseif opt == "e" then
      opts.execute[#opts.execute + 1] = optarg
    elseif opt == "l" then
      opts.load[#opts.load + 1] = optarg
    elseif opt == "i" then
      opts.interactive = true
    elseif opt == "v" then
      opts.version = true
    elseif opt == "E" then
      -- Ignore environment variables (already handled by lua)
    elseif opt == "W" then
      opts.warnings = true
    elseif opt == "h" or opt == "help" then
      opts.help = true
      return opts
    elseif opt == "compile" then
      opts.compile = optarg
      return opts
    elseif opt == "compile-strict" then
      opts.compile_strict = optarg
      return opts
    elseif opt == "format" then
      opts.format = optarg
      return opts
    elseif opt == "fix" then
      opts.fix = optarg
      return opts
    elseif opt == "check" then
      -- The kind is the flag's argument; the file is the next
      -- positional, which getopt has left in `r.args`.
      opts.check_kind = optarg
      opts.check_file = r.args[1]
      return opts
    elseif opt == "embed" then
      opts.embed[#opts.embed + 1] = optarg
    elseif opt == "output" then
      opts.output = optarg
    elseif opt == "extract" then
      opts.extract = optarg
      return opts
    elseif opt == "examples" then
      opts.examples = optarg or ""
      return opts
    elseif opt == "benchmark" then
      opts.benchmark = optarg
      return opts
    elseif opt == "docs" then
      opts.docs = optarg or ""
      return opts
    elseif opt == "welcome" then
      opts.welcome = true
    elseif opt == "test" then
      opts.test_output = optarg
      opts.test_argv = payload or {}
      return opts
    elseif opt == "report" then
      opts.report_paths = r.args
      return opts
    elseif opt == "coverage-report" then
      opts.coverage_report_paths = r.args
      return opts
    elseif opt == "build" then
      opts.build_mode = optarg
      opts.build_argv = payload or {}
      return opts
    elseif opt == "make" then
      opts.make_verb = optarg
      opts.make_argv = payload or {}
      return opts
    elseif opt == "skill" then
      opts.skill = optarg
      return opts
    elseif opt == "write-if-changed" then
      opts.write_if_changed = true
    elseif opt == "include-dir" then
      opts.include_dirs[#opts.include_dirs + 1] = optarg
    end
  end

  -- Handle script and script args
  if script_idx then
    opts.script = arg[script_idx]
    opts.script_args[0] = arg[script_idx]
    local arg_num = 1
    for k = script_idx + 1, #arg do
      if arg[k] ~= "--" then
        opts.script_args[arg_num] = arg[k]
        arg_num = arg_num + 1
      end
    end
    opts.script_args[-1] = arg[-1]
  end

  return opts
end

local run = require("_cli.run")

local function main(): integer, string
  local opts = parse_args()

  if opts.error then
    return 1, opts.error
  end

  -- Apply env var fallbacks (CLI args take priority)
  local embed_env = os.getenv("COSMIC_EMBED")
  if embed_env and #opts.embed == 0 then
    for p in embed_env:gmatch("[^:]+") do
      opts.embed[#opts.embed + 1] = p
    end
  end
  local output_env = os.getenv("COSMIC_OUTPUT")
  if output_env and not opts.output then
    opts.output = output_env
  end
  local extract_env = os.getenv("COSMIC_EXTRACT")
  if extract_env and not opts.extract then
    opts.extract = extract_env
  end
  if opts.version then return handlers.handle_version() end
  if opts.help then io.write(help.generate() .. "\n"); return 0 end
  if opts.welcome then io.write(handlers.generate_welcome()); return 0 end

  -- Show welcome on first invocation (skip when --help/--version/--welcome handled above)
  if not os.getenv("COSMIC_NO_WELCOME") then
    local welcome = require("_cli.welcome")
    if not welcome.was_shown() then
      local tty = require("cosmic.tty")
      if tty.stderr_isatty() then
        io.stderr:write(handlers.generate_welcome())
        welcome.mark_shown()
      end
    end
  end
  if opts.compile then return handlers.handle_compile(opts.compile, opts.output, opts.write_if_changed, opts.include_dirs) end
  if opts.compile_strict then return handlers.handle_compile(opts.compile_strict, opts.output, opts.write_if_changed, opts.include_dirs, true) end
  if opts.format then return handlers.handle_format(opts.format, opts.output, opts.write_if_changed) end
  if opts.fix then return handlers.handle_format(opts.fix, opts.fix, true) end
  if opts.check_kind then
    return require("_cli.check").run(opts.check_kind, opts.check_file,
      opts.include_dirs)
  end
  if #opts.embed > 0 then return handlers.handle_embed(opts.embed, opts.output, opts.exe) end
  if opts.extract then return handlers.handle_extract(opts.extract, opts.exe) end

  if opts.examples ~= nil then
    local module_name = cli_args.resolve_optional_arg("--examples", opts.examples)
    return handlers.handle_examples(module_name)
  end

  if opts.benchmark then return handlers.handle_benchmark(opts.benchmark) end

  if opts.docs ~= nil then
    local query = cli_args.resolve_optional_arg("--docs", opts.docs)
    return handlers.handle_docs(query)
  end

  if opts.test_argv then
    if #opts.test_argv == 0 then
      return 1, "cosmic-lua: --test requires: --test <output> <cmd>...\nSee: cosmic-lua --help"
    end
    local testrun = require("cosmic.testrun")
    return testrun.run(opts.test_argv, opts.test_output)
  end

  if opts.report_paths then
    local testrun = require("cosmic.testrun")
    return testrun.report(opts.report_paths)
  end

  if opts.coverage_report_paths then
    return require("cosmic.coverage").report(opts.coverage_report_paths)
  end

  -- `SHELL := cosmic`: make hands one recipe line to `-c`, which runs
  -- it as argv through the same closed vocabulary `--build` dispatches.
  if opts.recipe ~= nil then
    return require("_cli.driver").recipe(opts.recipe)
  end

  if opts.build_mode then
    return require("_cli.driver").build(opts.build_mode, opts.build_argv)
  end

  if opts.make_verb then
    local make_argv: {string} = {opts.make_verb}
    for _, p in ipairs(opts.make_argv or {}) do
      make_argv[#make_argv + 1] = p
    end
    return handlers.handle_make(make_argv)
  end

  if opts.skill then return handlers.handle_skill(opts.skill) end

  -- Handle -W warnings
  if opts.warnings then
    warn = function(...: string)
      local msg = table.concat({...}, " ")
      error("warning: " .. msg, 2)
    end
  end

  -- Load libraries
  for _, name in ipairs(opts.load) do
    require(name)
  end

  -- Execute strings
  for _, code in ipairs(opts.execute) do
    local chunk, err = load(code, "=(command line)")
    if chunk then
      chunk()
    else
      return 1, "cosmic-lua: " .. (err or "error loading command")
    end
  end

  -- Execute script file
  if opts.script then
    _G.arg = opts.script_args as {string} -- cast: arg map includes 0/-1 keys
    -- Arm line-coverage collection when COSMIC_COVERAGE names a
    -- directory (guarded so the common path never loads the module)
    local cov_dump: function() = nil
    if os.getenv("COSMIC_COVERAGE") then
      cov_dump = require("cosmic.coverage").enable_from_env()
    end
    local chunk, err = handlers.load_script_file(opts.script)
    if not chunk then
      local msg = err or "error loading script"
      msg = run.augment_module_errors(msg)
      return 1, "cosmic-lua: " .. msg
    end
    local run_chunk = chunk as function(...: any): any ... -- cast: function shape
    local args: {string} = {}
    for i, a in pairs(opts.script_args) do
      if i >= 1 then args[i] = a end
    end
    local results: {any} = table.pack(xpcall(function()
          run_chunk(table.unpack(args))
        end, run.trim_traceback))
    if cov_dump then
      cov_dump()
    end
    local ok = results[1] as boolean -- cast: from any
    if not ok then
      return 1, results[2] as string -- cast: from any
    end
    return 0
  end

  -- Interactive mode or REPL
  if opts.interactive or (#opts.execute == 0 and #opts.load == 0 and #arg == 0) then
    handlers.run_repl()
    return 0
  end

  return 0
end

local code, msg = main()
if msg then
  io.stderr:write(msg .. "\n")
end
os.exit(code)
