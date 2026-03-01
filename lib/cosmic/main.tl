-- cosmic-lua dispatcher
-- entry point for cosmic binary that handles special args and dispatches to features

global warn: function(...: any)

require("tl").loader()
if not os.getenv("COSMIC_NO_REQUIRE_HINTS") then
  require("cosmic.require").install()
end

local getopt = require("cosmic.getopt")
local cli_args = require("cosmic.args")
local help = require("cosmic.help")
local handlers = require("cosmic.main_handlers")

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
  check_format: string
  check_types: string
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
  make: string
  skill: string
  write_if_changed: boolean
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
    check_format = nil,
    check_types = nil,
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
    make = nil,
    skill = nil,
    write_if_changed = false,
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

  local parser = getopt.new(cosmic_args, shortopts, longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end

    if opt == "?" then
      opts.error = "cosmic-lua: unknown option '" .. optarg .. "'"
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
    elseif opt == "format" then
      opts.format = optarg
      return opts
    elseif opt == "check-format" then
      opts.check_format = optarg
      return opts
    elseif opt == "check-types" then
      opts.check_types = optarg
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
      opts.test_argv = parser:remaining()
      return opts
    elseif opt == "report" then
      opts.report_paths = parser:remaining()
      return opts
    elseif opt == "make" then
      opts.make = optarg or ""
      return opts
    elseif opt == "skill" then
      opts.skill = optarg
      return opts
    elseif opt == "write-if-changed" then
      opts.write_if_changed = true
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

--- Resolve optional arg value that may be space-separated.
--- For flags like --docs, --examples, --make where getopt returns ""
--- but the value may be the next positional arg.
local function resolve_optional_arg(flag: string, value: string): string
  if value ~= "" then return value end
  for i = 1, #arg do
    if arg[i] == flag then
      if i < #arg and not arg[i + 1]:match("^%-") then
        return arg[i + 1]
      end
      break
    end
  end
  return ""
end

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
    local welcome = require("cosmic.welcome")
    if not welcome.was_shown() then
      local tty = require("cosmic.tty")
      if tty.stderr_isatty() then
        io.stderr:write(handlers.generate_welcome())
        welcome.mark_shown()
      end
    end
  end
  if opts.compile then return handlers.handle_compile(opts.compile, opts.output, opts.write_if_changed) end
  if opts.format then return handlers.handle_format(opts.format, opts.output, opts.write_if_changed) end
  if opts.check_format then return handlers.handle_check_format(opts.check_format) end
  if opts.check_types then return handlers.handle_check_types(opts.check_types) end
  if #opts.embed > 0 then return handlers.handle_embed(opts.embed, opts.output) end
  if opts.extract then return handlers.handle_extract(opts.extract) end
  if opts.check_examples then return handlers.handle_check_examples(opts.check_examples) end

  if opts.examples ~= nil then
    local module_name = resolve_optional_arg("--examples", opts.examples)
    return handlers.handle_examples(module_name)
  end

  if opts.benchmark then return handlers.handle_benchmark(opts.benchmark) end

  if opts.docs ~= nil then
    local query = resolve_optional_arg("--docs", opts.docs)
    return handlers.handle_docs(query)
  end

  if opts.test_argv then
    local testrun = require("cosmic.testrun")
    return testrun.run(opts.test_argv, opts.test_output)
  end

  if opts.report_paths then
    local testrun = require("cosmic.testrun")
    return testrun.report(opts.report_paths)
  end

  if opts.make ~= nil then
    local make_dir = resolve_optional_arg("--make", opts.make)
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
    local chunk, err = handlers.load_script_file(opts.script)
    if not chunk then
      return 1, "cosmic-lua: " .. (err or "error loading script")
    end
    local args: {string} = {}
    for i = 1, #opts.script_args do
      args[i] = opts.script_args[i]
    end
    chunk(table.unpack(args))
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
