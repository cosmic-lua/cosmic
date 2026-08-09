-- cosmic-lua dispatcher: entry point for the cosmic binary, which
-- handles special args and dispatches to features.

global warn: function(...: any)

-- The zip root IS the module root: the payload sits at /zip/cosmic/**
-- while cosmopolitan's default path is /zip/.lua/-rooted. Inserted ahead
-- of that default. It does NOT sit behind LUA_PATH: an artifact answers
-- for itself, and the generated embed wrapper prepends the same root one
-- frame earlier anyway. Resolving against a project tree is a separate
-- mechanism with its own channel -- see --modules below.
local at = package.path:find("/zip/.lua/", 1, true) or 1
package.path = package.path:sub(1, at - 1) ..
"/zip/?.lua;/zip/?/init.lua;" .. package.path:sub(at)

-- `--modules <manifest>`: resolve this run's requires against the
-- project the build is standing in, ahead of /zip. Acted on HERE,
-- before every require but one, because a module already in
-- package.loaded is never searched again: anything loaded first -- the
-- dispatcher's own args, help and handlers -- would be pinned to the
-- binary's copy whatever the manifest said, so a test of `_cli.args`
-- would test /zip's. cosmic.searcher is that one exception and stays
-- the binary's, which is why it reads the manifest with io.open. The
-- scan rule is its own; see docs/design/make/resolution.md.
local searcher = require("cosmic.searcher")
-- A named manifest that cannot be installed is worth a line on
-- stderr (#1001); an argv with no --modules returns no message.
local _margs_ok, margs_err = searcher.install_argv_manifest(arg)
if margs_err then
  io.stderr:write("cosmic-lua: --modules: " .. margs_err .. "\n")
end

-- cosmic-owned runtime .tl searcher: resolves and compiles .tl
-- modules through cosmic.teal, fails the require() on compile errors,
-- and caches compiled output. See cosmic.searcher for the details.
searcher.install()
if not os.getenv("COSMIC_NO_REQUIRE_HINTS") then
  require("_cli.require_hints").install()
end

local flags = require("cosmic.flags")
local cli_args = require("_cli.args")
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
  recipe: string
  make_verb: string
  make_argv: {string}
  write_if_changed: boolean
  include_dirs: {string}
  error: string
end

-- Parse arguments against the _cli.args spec via cosmic.flags (#991).
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
  -- --test and --make are followed by a FOREIGN argv — the child's own
  -- flags, or a path list. getopt permutes, so it would eat those as
  -- cosmic options; slice the payload off and parse only to the option's
  -- own argument. Without it a --test child runs bare, hits the REPL and
  -- exits 0, so a stage reports a pass without ever running.
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
      -- --make joins them a: `--make <verb> [paths…]` is a verb plus
      -- a path list, and a path is a positional getopt would permute
      -- into its own option parse.
      if opt_name == "test" or opt_name == "make"
      or opt_name:find("^test=") or opt_name:find("^make=") then
        -- `--make=verb` embeds the verb; the space form has it at i+1.
        local eq = opt_name:find("=", 1, true) ~= nil
        local vstart = eq and i + 1 or i + 2
        payload = {}
        local from = arg[vstart] == "--" and vstart + 1 or vstart
        for k = from, #arg do
          payload[#payload + 1] = arg[k]
        end
        payload_parse_end = eq and i or i + 1
        script_idx = nil
        break
      elseif long_greedy[opt_name] then
        script_idx = nil
        break
      elseif long_extra_arg[opt_name:match("^([^=]+)=") or opt_name] then
        i = i + (opt_name:find("=", 1, true) and 2 or 3)
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

  local p0, perr = flags.parse(cli_args.spec, cosmic_args)
  if not p0 then
    -- flags errors arrive unprefixed (#991); this program adds its
    -- name, plus a targeted usage hint for the multi-argument flags.
    local hints: {string: string} = {
      ["--test"] = "--test requires: --test <output> <cmd>...",
      ["--make"] = "--make requires: --make <verb> [paths...]",
      ["--embed"] = "--embed requires: --embed <path>",
      ["--output"] = "--output requires: --output <file>",
    }
    local msg = perr or "failed to parse arguments"
    local needs_value = msg:match("^option requires a value: (%-%-%S+)$")
    if needs_value and hints[needs_value] then
      opts.error = "cosmic-lua: " .. hints[needs_value]
      .. "\nSee: cosmic-lua --help"
    else
      opts.error = "cosmic-lua: " .. msg .. "\nSee: cosmic-lua --help"
    end
    return opts
  end
  local p = p0

  -- Wholesale mapping: the mutually-exclusive command flags dispatch
  -- in main()'s fixed order, which the old first-flag-wins parse loop
  -- approximated anyway.
  opts.exe = p.values["exe"]
  opts.output = p.values["output"]
  opts.write_if_changed = p.switches["write-if-changed"]
  for _, d in ipairs(p.lists["include-dir"]) do
    opts.include_dirs[#opts.include_dirs + 1] = d
  end
  opts.recipe = p.values["recipe"]
  for _, code in ipairs(p.lists["execute"]) do
    opts.execute[#opts.execute + 1] = code
  end
  for _, name in ipairs(p.lists["load"]) do
    opts.load[#opts.load + 1] = name
  end
  opts.interactive = p.switches["interactive"]
  opts.version = p.switches["version"]
  opts.warnings = p.switches["warn"]
  opts.help = p.help
  opts.compile = p.values["compile"]
  opts.compile_strict = p.values["compile-strict"]
  opts.format = p.values["format"]
  opts.fix = p.values["fix"]
  if p.values["check"] then
    -- The kind is the flag's argument; the file is the next
    -- positional, which the parser has left in p.args.
    opts.check_kind = p.values["check"]
    opts.check_file = p.args[1]
  end
  for _, path in ipairs(p.lists["embed"]) do
    opts.embed[#opts.embed + 1] = path
  end
  opts.extract = p.values["extract"]
  opts.examples = p.values["examples"]
  opts.benchmark = p.values["benchmark"]
  opts.docs = p.values["docs"]
  opts.welcome = p.switches["welcome"]
  if p.values["test"] then
    opts.test_output = p.values["test"]
    opts.test_argv = payload or {}
  end
  if p.switches["report"] then
    opts.report_paths = p.args
  end
  if p.switches["coverage-report"] then
    opts.coverage_report_paths = p.args
  end
  if p.values["make"] then
    opts.make_verb = p.values["make"]
    opts.make_argv = payload or {}
  end
  -- --modules is acted on at the top of this file.

  -- A command flag ends the run before any script dispatch, matching
  -- the old parse loop's early returns.
  if opts.recipe or opts.help or opts.compile or opts.compile_strict
  or opts.format or opts.fix or opts.check_kind or opts.extract
  or opts.examples or opts.benchmark or opts.docs or opts.test_output
  or opts.report_paths or opts.coverage_report_paths or opts.make_verb then
    return opts
  end

  -- Handle script and script args
  if script_idx then
    opts.script = arg[script_idx]
    opts.script_args[0] = arg[script_idx]
    -- Drop one leading `--` separator; keep later ones (a script's own).
    local start = script_idx + 1
    if arg[start] == "--" then
      start = start + 1
    end
    local arg_num = 1
    for k = start, #arg do
      opts.script_args[arg_num] = arg[k]
      arg_num = arg_num + 1
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
  if opts.help then io.write(require("_cli.help").generate() .. "\n"); return 0 end
  if opts.welcome then io.write(handlers.generate_welcome()); return 0 end

  -- First-run welcome, tty gate first: the banner only ever prints to a terminal,
  -- so headless boots never load _cli.welcome (#973). Still once, on the first tty.
  if not os.getenv("COSMIC_NO_WELCOME") then
    local tty = require("cosmic.tty")
    if tty.is_tty(2) then
      local welcome = require("_cli.welcome")
      if not welcome.was_shown() then
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
    local testrun = require("_tool.testrun")
    -- The runner reports, the caller prints (#992): a runner failure
    -- comes back as a message, prefixed here with the flag it ran for.
    local code, run_msg = testrun.run(opts.test_argv, opts.test_output)
    if run_msg then
      return code, "cosmic-lua: --test: " .. run_msg
    end
    return code
  end

  if opts.report_paths then
    local testrun = require("_tool.testrun")
    return testrun.report(opts.report_paths)
  end

  if opts.coverage_report_paths then
    return require("_tool.coverage.report").report(opts.coverage_report_paths)
  end

  -- `SHELL := cosmic`: make hands one recipe line to `-c`, which runs
  -- it as argv through a closed vocabulary of build verbs.
  if opts.recipe ~= nil then
    return require("_cli.driver").recipe(opts.recipe)
  end

  if opts.make_verb then
    local make_argv: {string} = {opts.make_verb}
    for _, p in ipairs(opts.make_argv or {}) do
      make_argv[#make_argv + 1] = p
    end
    return handlers.handle_make(make_argv)
  end

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
