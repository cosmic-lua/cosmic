-- cosmic-lua dispatcher: entry point for the cosmic binary, which
-- handles special args and dispatches to features.

global warn: function(...: any)

-- The zip root IS the module root, ahead of cosmopolitan's /zip/.lua/
-- default and never behind LUA_PATH: an artifact answers for itself.
-- This is the bootstrap that makes cosmic.searcher reachable below;
-- install_zip() then resolves /zip through a searcher instead.
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
-- The /zip searcher: one zipos open per module the binary carries,
-- where the stock searcher probes and then reopens. Installed before
-- the manifest searcher, which takes the same seat: --modules outranks /zip.
searcher.install_zip()
-- A named manifest that cannot be installed is worth a line on
-- stderr; an argv with no --modules returns no message.
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

local cli_args = require("_cli.args")
local handlers = require("_cli.main_handlers")
local parse = require("_cli.parse")

local run = require("_cli.run")

local function main(): integer, string
  local opts = parse.parse_args()

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
  -- so headless boots never load _cli.welcome. Still once, on the first tty.
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
  if handlers.refuse_combined_file_commands(#opts.format, #opts.fix,
    opts.check_kind ~= nil) then
    return 1
  end
  if #opts.format > 0 then
    if #opts.format > 1 and opts.output then
      io.stderr:write("cosmic-lua: --output takes one file; " ..
        "--format printed several\n")
      return 1
    end
    return cli_args.over_paths(opts.format, function(path: string): integer
        -- Parenthesized: handle_format returns (code, err) and this
        -- wants the code alone.
        return (handlers.handle_format(path, opts.output, opts.write_if_changed))
      end)
  end
  if #opts.fix > 0 then
    return cli_args.over_paths(opts.fix, function(path: string): integer
        return (handlers.handle_format(path, path, true))
      end)
  end
  if opts.check_kind then
    return require("_cli.check").run(opts.check_kind, opts.check_files,
      opts.include_dirs)
  end
  if opts.find_pattern then
    return require("_cli.find").run(opts.find_pattern, opts.find_paths)
  end
  if opts.rewrite_pattern then
    return require("_cli.rewrite").run(opts.rewrite_pattern, opts.rewrite_paths,
      opts.rewrite_apply)
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
    -- The runner reports, the caller prints: a runner failure
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
    local cov_dump: function() | nil = nil
    if os.getenv("COSMIC_COVERAGE") then
      cov_dump = require("cosmic.coverage").enable_from_env()
    end
    local chunk, err = handlers.load_script_file(opts.script)
    if not chunk then
      local msg = err or "error loading script"
      msg = run.augment_module_errors(msg)
      return 1, "cosmic-lua: " .. msg
    end
    local run_chunk = chunk
    local args: {string} = {}
    for i, a in pairs(opts.script_args) do
      if i >= 1 then args[i] = a end
    end
    -- run_chunk's wrapper returns a string so xpcall types (boolean, string)
    local ok, script_err = xpcall(function(): string
        run_chunk(table.unpack(args))
        return ""
      end, run.trim_traceback)
    if cov_dump then
      cov_dump()
    end
    if not ok then return 1, script_err end
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
