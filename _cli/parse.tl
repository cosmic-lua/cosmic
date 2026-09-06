--- Command-line argument parsing for the cosmic dispatcher.
--- Parses argv (via cosmic.flags against the _cli.args spec) into an
--- Options record; main.tl dispatches on the result.

local flags = require("cosmic.flags")
local cli_args = require("_cli.args")

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
  --- The file-taking flags all take a LIST. A path the tool accepted
  --- and then ignored is the one outcome a gate must not have.
  format: {string}
  fix: {string}
  --- The kind named by `--check <kind>`, and the files it applies to.
  check_kind: string
  check_files: {string}
  --- The pattern named by `--find <pattern>`, and the paths it searches
  --- (empty means the project's own `.tl` sources).
  find_pattern: string
  find_paths: {string}
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

-- Parse arguments against the _cli.args spec via cosmic.flags.
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
    format = {},
    fix = {},
    check_files = {},
    welcome = false,
    write_if_changed = false,
    include_dirs = {},
  }

  local short_needs_arg = cli_args.short_needs_arg
  local long_needs_arg = cli_args.long_needs_arg

  -- Options that consume all remaining arguments (no script after them).
  -- The file-taking flags belong here because they take a path LIST:
  -- anything else stops this scan at the first positional past a flag's
  -- declared arity and reads the rest as a script name, so the parser
  -- never sees those paths. Greedy, they arrive as the list they are.
  local long_greedy: {string: boolean} = {
    ["report"] = true,
    ["coverage-report"] = true,
    ["check"] = true,
    ["find"] = true,
    ["fix"] = true,
    ["format"] = true,
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
      elseif long_greedy[opt_name:match("^([^=]+)=") or opt_name] then
        script_idx = nil
        break
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
    -- flags errors arrive unprefixed; this program adds its
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
  -- The flag's own argument is the first path; the rest are the
  -- positionals the parser left in p.args, so `--fix a.tl b.tl` names
  -- both files. Leftover positionals carry no position, so a run
  -- combining these commands is refused at dispatch rather than
  -- guessed at here.
  if p.values["format"] then
    opts.format = cli_args.with_extra_paths(p.values["format"], p.args)
  end
  if p.values["fix"] then
    opts.fix = cli_args.with_extra_paths(p.values["fix"], p.args)
  end
  if p.values["check"] then
    -- The kind is the flag's argument; the files are the positionals,
    -- which the parser has left in p.args.
    opts.check_kind = p.values["check"]
    opts.check_files = cli_args.with_extra_paths(nil, p.args)
  end
  if p.values["find"] then
    -- The pattern is the flag's argument; the paths are the
    -- positionals left in p.args (empty means the whole project).
    opts.find_pattern = p.values["find"]
    opts.find_paths = p.args
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
  -- --modules is acted on at the top of main.tl.

  -- A command flag ends the run before any script dispatch, matching
  -- the old parse loop's early returns.
  if opts.recipe or opts.help or opts.compile or opts.compile_strict
  or #opts.format > 0 or #opts.fix > 0 or opts.check_kind or opts.find_pattern
  or opts.extract or opts.examples or opts.benchmark or opts.docs
  or opts.test_output or opts.report_paths or opts.coverage_report_paths
  or opts.make_verb then
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

return {
  parse_args = parse_args,
  Options = Options,
}
