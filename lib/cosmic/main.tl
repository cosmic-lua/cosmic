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
  compile: string -- Input file for --compile (outputs to stdout)
  format: string -- Input file for --format (outputs to stdout)
  check_format: string -- Input file for --check-format (exits 0 if formatted)
  check_types: string -- Input file for --check-types
  embed: {string} -- Files to embed via --embed
  output: string -- Output file for --embed (defaults to "cosmic")
  extract: string -- Output dir for --extract
  check_examples: string -- Input file for --check-examples (run examples)
  examples: string -- Module for --examples (nil = not set, "" = list all)
  benchmark: string -- Input file for --benchmark (run benchmarks)
  docs: string -- Module/symbol/query for --docs
  welcome: boolean -- Show welcome message
  test_argv: {string} -- Command for --test
  test_output: string -- Output base for --test
  report_paths: {string} -- Paths for --report
  make: string -- Directory for --make (nil = not set, "" = current dir)
  error: string -- Parse error message
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
      -- Check if followed by : (required arg) but not :: (optional arg)
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
      -- Explicit end of options
      script_idx = i + 1
      break
    elseif a:sub(1, 2) == "--" then
      -- Long option
      local opt_name = a:sub(3)
      if long_greedy[opt_name] then
        -- Greedy option: consumes all remaining args, no script
        script_idx = nil
        break
      elseif long_extra_arg[opt_name] then
        -- Takes required arg + one extra positional arg
        i = i + 3
      elseif not opt_name:find("=") and long_needs_arg[opt_name] then
        -- Takes next arg
        i = i + 2
      else
        i = i + 1
      end
    elseif a:sub(1, 1) == "-" and #a > 1 then
      -- Short option
      if #a == 2 and short_needs_arg[a:sub(2, 2)] then
        -- Single short option that takes arg
        i = i + 2
      else
        i = i + 1
      end
    else
      -- First non-option is the script name
      script_idx = i
      break
    end
  end

  -- Only parse cosmic options (before script name)
  local cosmic_args: {string} = {}
  if script_idx then
    for k = 1, script_idx - 1 do
      if arg[k] ~= "--" then -- Exclude -- separator
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

  -- Iterate through all options
  while true do
    local opt, optarg = parser:next()
    if not opt then
      break
    end

    if opt == "?" then
      -- Unknown cosmic option
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
    end
  end

  -- Handle script and script args (from original arg, starting at script_idx)
  if script_idx then
    opts.script = arg[script_idx]
    opts.script_args[0] = arg[script_idx]
    local arg_num = 1
    for k = script_idx + 1, #arg do
      -- Skip -- separator
      if arg[k] ~= "--" then
        opts.script_args[arg_num] = arg[k]
        arg_num = arg_num + 1
      end
    end
    opts.script_args[-1] = arg[-1]
  end

  return opts
end

--- Generate welcome message for first-run experience.
--- @return string The welcome message text
local function generate_welcome(): string
  return [[
Welcome to cosmic-lua!

Quick start:
  cosmic --docs [query]    search documentation (non-interactive)
  cosmic --help            show all options
  cosmic -i                start REPL (help() available interactively)

Run 'cosmic --welcome' to see this again.
]]

end

-- Interactive REPL using cosmopolitan's linenoise-based REPL
local function run_repl()
  io.write(_VERSION .. "  Copyright (C) 1994-2024 Lua.org, PUC-Rio\n")
  io.write("Type help() for docs, or use --docs <query> outside the REPL\n")

  require("cosmo")

  -- Inject help() into REPL
  local docs = require("cosmic.docs")
  rawset(_G, "help", function(query: string)
      local result = docs.run(query or "")
      print(result.output)
    end)

  require("cosmo.repl").start()
end

-- Load a script file (.tl or .lua)
-- Compiles .tl files through Teal, loads .lua files directly
local function load_script_file(script_path: string): function(...: any): any ..., string
  -- Compile .tl files through Teal, load .lua files directly
  if script_path:match("%.tl$") then
    local teal = require("cosmic.teal")
    local result = teal.compile(script_path)
    if not result.ok then
      return nil, teal.format_issues(result.errors)
    end
    -- Strip shebang from compiled code before loading (Lua parser doesn't handle shebangs)
    local code = result.code
    if code:sub(1, 2) == "#!" then
      local newline_pos = code:find("\n")
      if newline_pos then
        code = code:sub(newline_pos + 1)
      end
    end
    return load(code, "@" .. script_path)
  else
    return loadfile(script_path)
  end
end

--- Result from running docs command.
local record DocsRunResult
  ok: boolean
  output: string
end

--- Run docs command with smart matching.
--- Tries exact match first, then searches if no exact match found.
--- @param query string The query string (module, symbol, or search term)
--- @return DocsRunResult Result with ok status and output text
local function run_docs(query: string): DocsRunResult
  local docs = require("cosmic.docs")

  -- Try exact match first
  local result = docs.run(query)
  if result.ok then
    return {
      ok = true,
      output = result.output,
    }
  end

  -- If no exact match, try search
  local results = docs.search(query)
  if #results > 0 then
    return {
      ok = true,
      output = docs.render_search_results(results, query),
    }
  end

  -- No results at all
  return {
    ok = false,
    output = result.output,
  }
end


local function main(): integer, string
  local opts = parse_args()

  -- Handle parse errors
  if opts.error then
    return 1, opts.error
  end

  -- Show welcome on first invocation (to stderr, if TTY)
  -- Check early so it runs for -v, --help, -e, scripts, etc.
  if not os.getenv("COSMIC_NO_WELCOME") then
    local welcome = require("cosmic.welcome")
    if not welcome.was_shown() then
      local tty = require("cosmic.tty")
      if tty.stderr_isatty() then
        io.stderr:write(generate_welcome())
        welcome.mark_shown()
      end
    end
  end

  -- Handle -v / --version
  if opts.version then
    local mod = "cosmic.version"
    local ok, ver = pcall(require, mod)
    if ok then
      local record VersionInfo
        cosmic: string
        cosmos: string
      end
      local v = ver as VersionInfo
      io.write("cosmic-lua " .. v.cosmic .. " (cosmos " .. v.cosmos .. ", " .. _VERSION .. ")\n")
    else
      io.write(_VERSION .. "\n")
    end
    return 0
  end

  -- Handle --help
  if opts.help then
    io.write(help.generate() .. "\n")
    return 0
  end

  -- Handle --welcome
  if opts.welcome then
    io.write(generate_welcome())
    return 0
  end

  -- Handle --compile
  if opts.compile then
    local teal = require("cosmic.teal")
    local result = teal.compile(opts.compile)
    if result.ok then
      io.write(result.code)
      return 0
    else
      io.stderr:write(teal.format_issues(result.errors) .. "\n")
      return 1
    end
  end

  -- Handle --format
  if opts.format then
    local fmt = require("cosmic.format")
    local result = fmt.format_file(opts.format)
    if result.ok then
      io.write(result.code)
      return 0
    else
      io.stderr:write(fmt.format_issues(result.errors) .. "\n")
      return 1
    end
  end

  -- Handle --check-format
  if opts.check_format then
    local fmt = require("cosmic.format")
    local result = fmt.format_file(opts.check_format)
    if not result.ok then
      io.stderr:write(fmt.format_issues(result.errors) .. "\n")
      return 1
    end

    -- Read original file content
    local cio = require("cosmic.io")
    local original, read_err = cio.slurp(opts.check_format)
    if not original then
      io.stderr:write(opts.check_format .. ": " .. (read_err or "unknown error") .. "\n")
      return 1
    end

    if original == result.code then
      io.write("Format check passed\n")
      return 0
    else
      -- Report first differing line on stderr
      local orig_lines: {string} = {}
      for line in (original .. "\n"):gmatch("([^\n]*)\n") do
        orig_lines[#orig_lines + 1] = line
      end
      local fmt_lines: {string} = {}
      for line in (result.code .. "\n"):gmatch("([^\n]*)\n") do
        fmt_lines[#fmt_lines + 1] = line
      end
      local max = math.max(#orig_lines, #fmt_lines)
      for i = 1, max do
        if orig_lines[i] ~= fmt_lines[i] then
          io.stderr:write(string.format("%s:%d: format mismatch\n", opts.check_format, i))
          io.stderr:write(string.format("  have: %s\n", orig_lines[i] or "<eof>"))
          io.stderr:write(string.format("  want: %s\n", fmt_lines[i] or "<eof>"))
          break
        end
      end
      return 1
    end
  end

  -- Handle --check-types
  if opts.check_types then
    local teal = require("cosmic.teal")
    local result = teal.check(opts.check_types)

    if #result.warnings > 0 then
      io.stderr:write(teal.format_issues(result.warnings) .. "\n")
    end
    if #result.errors > 0 then
      io.stderr:write(teal.format_issues(result.errors) .. "\n")
    end

    if result.ok then
      io.write("Type check passed\n")
      return 0
    else
      return 1
    end
  end

  -- Handle --embed
  if #opts.embed > 0 then
    local embed = require("cosmic.embed")
    local result = embed.run(opts.embed, opts.output)
    io.write(result.message .. "\n")
    return result.ok and 0 or 1
  end

  -- Handle --extract
  if opts.extract then
    local embed = require("cosmic.embed")
    local result = embed.extract(opts.extract)
    io.write(result.message .. "\n")
    return result.ok and 0 or 1
  end

  -- Handle --check-examples
  if opts.check_examples then
    local example = require("cosmic.example")
    local result = example.run(opts.check_examples)
    io.write(example.format_results(opts.check_examples, result) .. "\n")
    return result.exit_code
  end

  -- Handle --examples (browse, read-only)
  if opts.examples ~= nil then
    local docs = require("cosmic.docs")
    local module_name = opts.examples

    -- For optional args with space-separated value, getopt doesn't consume it
    -- Check if there's a positional arg that should be the module name
    if module_name == "" then
      for i = 1, #arg do
        if arg[i] == "--examples" then
          -- Next arg (if exists and not an option) is the module name
          if i < #arg and not arg[i + 1]:match("^%-") then
            module_name = arg[i + 1]
          end
          break
        end
      end
    end

    if module_name == "" then
      local result = docs.run("examples")
      io.write(result.output .. "\n")
      return result.ok and 0 or 1
    else
      local result = docs.show_module_examples(module_name)
      io.write(result.output .. "\n")
      return result.ok and 0 or 1
    end
  end

  -- Handle --benchmark
  -- Supports: --benchmark file.tl or --benchmark file.tl:pattern
  if opts.benchmark then
    local benchmark = require("cosmic.benchmark")
    local file_path = opts.benchmark
    local filter: string = nil

    -- Check for colon-separated filter pattern
    local colon_pos = opts.benchmark:find(":[^/\\]") -- Avoid matching Windows paths or protocol prefixes
    if colon_pos then
      file_path = opts.benchmark:sub(1, colon_pos - 1)
      filter = opts.benchmark:sub(colon_pos + 1)
    end

    local result = benchmark.run(file_path, filter)
    io.write(benchmark.format_results(file_path, result) .. "\n")
    return result.exit_code
  end

  -- Handle --docs
  if opts.docs ~= nil then
    local query = opts.docs

    -- For optional args with space-separated value, getopt doesn't consume it
    -- Check if there's a positional arg that should be the query
    if query == "" then
      for i = 1, #arg do
        if arg[i] == "--docs" then
          -- Next arg (if exists and not an option) is the query
          if i < #arg and not arg[i + 1]:match("^%-") then
            query = arg[i + 1]
          end
          break
        end
      end
    end

    if query == "" then
      local docs = require("cosmic.docs")
      local result = docs.run("")
      io.write(result.output .. "\n")
      return result.ok and 0 or 1
    else
      local result = run_docs(query)
      if result.ok then
        io.write(result.output .. "\n")
        return 0
      else
        io.stderr:write(result.output .. "\n")
        return 1
      end
    end
  end

  -- Handle --test
  if opts.test_argv then
    local testrun = require("cosmic.testrun")
    return testrun.run(opts.test_argv, opts.test_output)
  end

  -- Handle --report
  if opts.report_paths then
    local testrun = require("cosmic.testrun")
    return testrun.report(opts.report_paths)
  end

  -- Handle --make
  if opts.make ~= nil then
    local make_dir = opts.make

    -- For optional args with space-separated value, getopt doesn't consume it
    -- Check if there's a positional arg that should be the directory
    if make_dir == "" then
      for i = 1, #arg do
        if arg[i] == "--make" then
          -- Next arg (if exists and not an option) is the directory
          if i < #arg and not arg[i + 1]:match("^%-") then
            make_dir = arg[i + 1]
          end
          break
        end
      end
    end

    local mk = require("cosmic.make")
    local ok, result = mk.run(make_dir ~= "" and make_dir or nil)
    if ok then
      return 0
    else
      io.stderr:write((result or "make generation failed") .. "\n")
      return 1
    end
  end

  -- Handle -W warnings: convert warnings to errors
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
    local chunk, err = load_script_file(opts.script)
    if not chunk then
      return 1, "cosmic-lua: " .. (err or "error loading script")
    end
    -- Call chunk with script args as varargs (matching standard lua behavior)
    -- Standard lua passes arg[1], arg[2], ... as varargs to the script
    -- Note: table.unpack has a limit of ~250 args, but this is not a practical concern
    local args: {string} = {}
    for i = 1, #opts.script_args do
      args[i] = opts.script_args[i]
    end
    chunk(table.unpack(args))
    return 0
  end

  -- Interactive mode or REPL
  if opts.interactive or (#opts.execute == 0 and #opts.load == 0 and #arg == 0) then
    run_repl()
    return 0
  end

  -- If we have -e or -l but no script, exit normally
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
