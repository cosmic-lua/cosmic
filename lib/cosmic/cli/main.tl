-- cosmic-lua dispatcher
-- entry point for cosmic binary that handles special args and dispatches to features

global warn: function(...: any)

-- Install a lazy searcher at the end of package.searchers instead of
-- eagerly require("tl")-ing the ~15k-line Teal compiler on every startup,
-- including runs that never touch a .tl file. It loads the real compiler
-- and replaces itself on first invocation, i.e. the first require() that
-- the default Lua searcher can't resolve.
--
-- The end position (not position 2, where tl.loader() itself inserts)
-- ensures the default Lua file searcher runs first, so pre-compiled .lua
-- modules are found before falling back to compiling .tl source. Without
-- this, setting TL_PATH causes ~330ms startup overhead from recompiling
-- cosmic modules. See: https://github.com/whilp/cosmic/issues/377
if package.searchers then
  local function lazy_tl_searcher(module_name: string): any, any
    local tl = require("tl")
    tl.loader()
    local real = table.remove(package.searchers, 2)
    package.searchers[#package.searchers] = real
    local loader_fn, extra = real(module_name)
    return loader_fn, extra
  end
  table.insert(package.searchers, lazy_tl_searcher)
end
if not os.getenv("COSMIC_NO_REQUIRE_HINTS") then
  require("cosmic.require").install()
end

local getopt = require("cosmic.getopt")
local cli_args = require("cosmic.cli.args")
local help = require("cosmic.cli.help")
local handlers = require("cosmic.cli.main_handlers")

-- Parsed options record
local record Opts
  execute: {string}
  load: {string}
  interactive: boolean
  version: boolean
  warnings: boolean
  help: boolean
  script: string
  script_args: {integer: string}
  compile: string
  format: string
  fix: string
  check_format: string
  check_types: string
  check_style: string
  embed: {string}
  output: string
  extract: string
  check_examples: string
  examples: string
  benchmark: string
  docs: string
  welcome: boolean
  test_argv: {string}
  test_output: string
  report_paths: {string}
  coverage_report_paths: {string}
  make: string
  skill: string
  write_if_changed: boolean
  include_dirs: {string}
  error: string
end

-- Parse arguments using cosmo.getopt iterator API
local function parse_args(): Opts
  local opts: Opts = {
    execute = {},
    load = {},
    interactive = false,
    version = false,
    warnings = false,
    help = false,
    script = nil,
    script_args = {},
    compile = nil,
    format = nil,
    fix = nil,
    check_format = nil,
    check_types = nil,
    check_style = nil,
    embed = {},
    output = nil,
    extract = nil,
    check_examples = nil,
    examples = nil,
    benchmark = nil,
    docs = nil,
    welcome = false,
    test_argv = nil,
    test_output = nil,
    report_paths = nil,
    coverage_report_paths = nil,
    make = nil,
    skill = nil,
    write_if_changed = false,
    include_dirs = {},
    error = nil,
  }

  local shortopts = cli_args.shortopts
  local longopts: {getopt.LongOpt} = cli_args.longopts

  -- Parse shortopts to build set of options that require arguments
  local short_needs_arg: {string: boolean} = {}
  local j = 1
  while j <= #shortopts do
    local c = shortopts:sub(j, j)
    if c ~= ":" then
      if j < #shortopts and shortopts:sub(j + 1, j + 1) == ":" and
      (j + 1 >= #shortopts or shortopts:sub(j + 2, j + 2) ~= ":") then
        short_needs_arg[c] = true
      end
    end
    j = j + 1
  end

  -- Parse longopts to build set of options that require arguments
  local long_needs_arg: {string: boolean} = {}
  for _, opt in ipairs(longopts) do
    if opt.has_arg == "required" then
      long_needs_arg[opt.name] = true
    end
  end

  -- Options that consume all remaining arguments (no script after them)
  local long_greedy: {string: boolean} = {
    ["report"] = true,
    ["test"] = true,
    ["coverage-report"] = true,
  }

  -- Options that take required arg + one additional positional arg
  local long_extra_arg: {string: boolean} = {}

  -- Find first non-option argument (script name) to know where to stop parsing
  local script_idx: integer = nil
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--" then
      script_idx = i + 1
      break
    elseif a:sub(1, 2) == "--" then
      local opt_name = a:sub(3)
      if long_greedy[opt_name] then
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
  else
    cosmic_args = arg
  end

  -- Check for removed flags before getopt (to avoid prefix matching)
  for _, a in ipairs(cosmic_args) do
    if a == "--check" or a:match("^%-%-check=") then
      opts.error = "cosmic-lua: --check was renamed to --check-types"
      return opts
    elseif a == "--example" or a:match("^%-%-example=") then
      opts.error = "cosmic-lua: --example was renamed to --check-examples"
      return opts
    end
  end

  local r0, perr = getopt.parse(cosmic_args, shortopts, longopts)
  if not r0 then
    opts.error = "cosmic-lua: " .. (perr or "failed to parse arguments")
    return opts
  end
  local r = r0 as getopt.Result

  -- A required argument that's absent lands in `missing` (named without
  -- dashes). Give a targeted usage hint where we have one, else a generic
  -- "requires an argument" message.
  if #r.missing > 0 then
    local m = r.missing[1]
    if m == "test" then
      opts.error = "cosmic-lua: --test requires: --test <output> <cmd>...\nSee: cosmic-lua --help"
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

  for _, o in ipairs(r.opts) do
    local opt = o.opt
    local optarg = o.arg

    if opt == "e" then
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
    elseif opt == "format" then
      opts.format = optarg
      return opts
    elseif opt == "fix" then
      opts.fix = optarg
      return opts
    elseif opt == "check-format" then
      opts.check_format = optarg
      return opts
    elseif opt == "check-types" then
      opts.check_types = optarg
      return opts
    elseif opt == "check-style" then
      opts.check_style = optarg
      return opts
    elseif opt == "embed" then
      opts.embed[#opts.embed + 1] = optarg
    elseif opt == "output" then
      opts.output = optarg
    elseif opt == "extract" then
      opts.extract = optarg
      return opts
    elseif opt == "check-examples" then
      opts.check_examples = optarg
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
      opts.test_argv = r.args
      return opts
    elseif opt == "report" then
      opts.report_paths = r.args
      return opts
    elseif opt == "coverage-report" then
      opts.coverage_report_paths = r.args
      return opts
    elseif opt == "make" then
      opts.make = optarg or ""
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

local run = require("cosmic.cli.run")

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
    local welcome = require("cosmic.cli.welcome")
    if not welcome.was_shown() then
      local tty = require("cosmic.tty")
      if tty.stderr_isatty() then
        io.stderr:write(handlers.generate_welcome())
        welcome.mark_shown()
      end
    end
  end
  if opts.compile then return handlers.handle_compile(opts.compile, opts.output, opts.write_if_changed, opts.include_dirs) end
  if opts.format then return handlers.handle_format(opts.format, opts.output, opts.write_if_changed) end
  if opts.fix then return handlers.handle_format(opts.fix, opts.fix, true) end
  if opts.check_format then return handlers.handle_check_format(opts.check_format) end
  if opts.check_types then return handlers.handle_check_types(opts.check_types, opts.include_dirs) end
  if opts.check_style then return handlers.handle_check_style(opts.check_style) end
  if #opts.embed > 0 then return handlers.handle_embed(opts.embed, opts.output) end
  if opts.extract then return handlers.handle_extract(opts.extract) end
  if opts.check_examples then return handlers.handle_check_examples(opts.check_examples) end

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

  if opts.make ~= nil then
    local make_dir = cli_args.resolve_optional_arg("--make", opts.make)
    local make_target: string = nil
    if make_dir ~= "" then
      for i = 1, #arg do
        if arg[i] == "--make" then
          if i + 1 < #arg and arg[i + 1] == make_dir and
          i + 2 <= #arg and not arg[i + 2]:match("^%-") then
            make_target = arg[i + 2]
          end
          break
        end
      end
    end
    return handlers.handle_make(make_dir, make_target)
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
    _G.arg = opts.script_args as {string}
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
    local run_chunk = chunk as function(...: any): any ...
    local args: {string} = {}
    for i = 1, #opts.script_args do
      args[i] = opts.script_args[i]
    end
    local results: {any} = table.pack(xpcall(function()
          run_chunk(table.unpack(args))
        end, run.trim_traceback))
    if cov_dump then
      cov_dump()
    end
    local ok = results[1] as boolean
    if not ok then
      return 1, results[2] as string
    end
    return 0
  end

  -- Interactive mode or REPL
  if opts.interactive or (#opts.execute == 0 and #opts.load == 0 and #arg == 0) then
    handlers.run_repl()
    return 0
  end

  if #opts.execute > 0 or #opts.load > 0 then
    return 0
  end

  return 0
end

local code, msg = main()
if msg then
  io.stderr:write(msg .. "\n")
end
os.exit(code)
