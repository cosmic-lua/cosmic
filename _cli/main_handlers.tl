--- Command handler functions for the cosmic CLI.
--- Each handler implements one CLI command flag.
local instrument = require("cosmic.instrument")

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

--- Interactive REPL using cosmopolitan's linenoise-based REPL.
local function run_repl()
  io.write(_VERSION .. "  Copyright (C) 1994-2024 Lua.org, PUC-Rio\n")
  io.write("Type help() for docs, or use --docs <query> outside the REPL\n")

  require("cosmo")

  local docs = require("cosmic.doc")
  rawset(_G, "help", function(query: string)
      local out, qerr = docs.query(query or "")
      print(out or qerr)
    end)

  require("cosmo.repl").start()
end

--- Load a script file (.tl or .lua): .tl through Teal (cached), .lua directly.
local function load_script_file(script_path: string): function(...: any): any ... | nil, string
  if script_path:match("%.tl$") then
    package.path = package.path .. ";/zip/.tl/?.tl" -- so teal can find cosmic modules
    local teal = require("cosmic.teal")
    local code, cerr = teal.compile_cached(script_path)
    if not code then
      return nil, cerr
    end
    local src = code
    if src:sub(1, 2) == "#!" then
      src = src:sub((src:find("\n") or 0) + 1)
    end
    return load(src, "@" .. script_path)
  else
    return loadfile(script_path)
  end
end

--- Handle --version flag.
local function handle_version(): integer
  -- Required here, not at the top: this file is on the boot surface
  -- (_make/stamp.tl's BOOT_MODULES), and `cosmic` loads the generated
  -- version module, which nothing else at boot needs.
  local v = require("cosmic").version_info()
  if v then
    io.write("cosmic-lua " .. v.cosmic .. " (cosmos " .. v.cosmos .. ", " .. _VERSION .. ")\n")
  else
    io.write(_VERSION .. "\n")
  end
  return 0
end

--- Write content to stdout or, with --write-if-changed and --output, atomically
--- to a file only when its content differs from what is already on disk.
local function write_output(content: string, output: string, write_if_changed: boolean): integer, string
  if not output or not write_if_changed then
    io.write(content)
    return 0
  end
  local fs = require("cosmic.fs")
  local existing, _ = fs.read(output)
  if existing == content then
    return 0
  end
  local unix = require("cosmo.unix")
  local tmp_fd, tmp_path = unix.mkstemp(output .. ".XXXXXX")
  if not tmp_fd then
    return 1, "write-if-changed: mkstemp failed for: " .. output
  end
  unix.close(tmp_fd)
  local ok, err = fs.write(tmp_path, content)
  if not ok then
    local _ok, _err = os.remove(tmp_path)
    return 1, "write-if-changed: failed to write tmp: " .. (err or "")
  end
  local rok, rerr = fs.move(tmp_path, output)
  if not rok then
    local _ok, _err = os.remove(tmp_path)
    return 1, "write-if-changed: rename failed: " .. (rerr or "")
  end
  return 0
end

--- Handle --compile / --compile-strict flags.
local function handle_compile(file: string, output?: string, write_if_changed?: boolean, include_dirs?: {string}, strict?: boolean): integer, string
  local span = instrument.begin("compile", file)
  local tealc = require("cosmic.teal")
  local result = tealc.compile_file(file, {include_dirs = include_dirs, strict = strict})
  local exit_code: integer
  local err_msg: string
  if result.ok then
    exit_code, err_msg = write_output(result.code, output, write_if_changed)
  else
    -- With hints, like --check types: `--make build` compiles through
    -- this path, so it is where a project author actually meets the
    -- un-narrowed `T | nil` errors.
    io.stderr:write(tealc.format_issues(result.errors, {hints = true}) .. "\n")
    exit_code = 1
  end
  instrument.finish(span, exit_code)
  return exit_code, err_msg
end

--- Handle --format flag.
local function handle_format(file: string, output?: string, write_if_changed?: boolean): integer, string
  local span = instrument.begin("format", file)
  local fmt = require("cosmic.format")
  local result = fmt.format_file(file)
  local exit_code: integer
  local err_msg: string
  if result.ok then
    exit_code, err_msg = write_output(result.code, output, write_if_changed)
  else
    io.stderr:write(fmt.format_issues(result.errors) .. "\n")
    exit_code = 1
  end
  instrument.finish(span, exit_code)
  return exit_code, err_msg
end

--- Render a line visibly by replacing tabs and trailing spaces with markers.
--- Used when have/want lines look the same but differ only in whitespace.
--- @param s string The line to render
--- @return string The line with whitespace made visible
local function render_whitespace(s: string): string
  local result = s:gsub("\t", "->")
  result = result:gsub("( +)$", function(spaces: string): string
      return string.rep("_", #spaces)
    end)
  return result
end

--- Handle --check fmt flag.
local function handle_check_format(file: string): integer
  local span = instrument.begin("check-format", file)
  local fmt = require("cosmic.format")
  local result = fmt.format_file(file)
  if not result.ok then
    io.stderr:write(fmt.format_issues(result.errors) .. "\n")
    instrument.finish(span, 1)
    return 1
  end

  local fs = require("cosmic.fs")
  local original, read_err = fs.read(file)
  if not original then
    io.stderr:write(file .. ": " .. (read_err or "unknown error") .. "\n")
    instrument.finish(span, 1)
    return 1
  end

  if original == result.code then
    io.write("Format check passed: " .. file .. "\n")
    instrument.finish(span, 0)
    return 0
  end

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
      local have = orig_lines[i] or "<eof>"
      local want = fmt_lines[i] or "<eof>"
      io.stderr:write(string.format("%s:%d: format mismatch\n", file, i))
      -- Context before the mismatch makes indentation-level errors legible
      for c = math.max(1, i - 2), i - 1 do
        io.stderr:write(string.format("        %s\n", orig_lines[c]))
      end
      -- When lines look identical but differ only in whitespace, render it visibly
      if have:gsub("%s", "") == want:gsub("%s", "") then
        io.stderr:write(string.format("  have: %s  (whitespace differs)\n", render_whitespace(have)))
        io.stderr:write(string.format("  want: %s  (whitespace differs)\n", render_whitespace(want)))
      else
        io.stderr:write(string.format("  have: %s\n", have))
        io.stderr:write(string.format("  want: %s\n", want))
      end
      break
    end
  end
  io.stderr:write(string.format(
      "  hint: run 'cosmic --fix %s' to fix in place, or 'cosmic --format %s' to preview\n",
      file, file))
  instrument.finish(span, 1)
  return 1
end

--- Handle --check types flag.
local function handle_check_types(file: string, include_dirs?: {string}): integer
  local span = instrument.begin("check-types", file)
  local tealc = require("cosmic.teal")
  local result = tealc.check_file(file, {include_dirs = include_dirs})

  if #result.warnings > 0 then
    io.stderr:write(tealc.format_issues(result.warnings, {hints = true}) .. "\n")
  end
  if #result.errors > 0 then
    io.stderr:write(tealc.format_issues(result.errors, {hints = true}) .. "\n")
  end

  if result.ok then
    io.write("Type check passed: " .. file .. "\n")
    instrument.finish(span, 0)
    return 0
  else
    instrument.finish(span, 1)
    return 1
  end
end

--- Handle --embed flag.
local function handle_embed(paths: {string}, output: string, exe?: string): integer
  local embed = require("cosmic.embed")
  local n, werr = embed.write(paths, {output = output, exe_path = exe})
  if not n then
    io.write((werr or "error: embed failed") .. "\n")
    return 1
  end
  io.write("embedded " .. n .. " file(s) into " .. (output or "cosmic") .. "\n")
  return 0
end

--- Handle --extract flag.
local function handle_extract(dir: string, exe?: string): integer
  local embed = require("cosmic.embed")
  local n, xerr = embed.extract(dir, exe and {exe_path = exe} or nil)
  if not n then
    io.write((xerr or "error: extract failed") .. "\n")
    return 1
  end
  io.write("extracted " .. n .. " file(s) to " .. dir .. "\n")
  return 0
end

--- Handle --check example flag.
local function handle_check_examples(file: string): integer
  local span = instrument.begin("check-examples", file)
  local example = require("_tool.example")
  local result = example.run(file)
  io.write(example.format_results(file, result) .. "\n")
  instrument.finish(span, result.exit_code)
  return result.exit_code
end

--- Handle --examples flag.
local function handle_examples(module_name: string): integer
  local docs = require("cosmic.doc")

  if module_name == "" then
    local out, qerr = docs.query("examples")
    io.write((out or qerr) .. "\n")
    return out and 0 or 1
  else
    local out, qerr = docs.module_examples(module_name)
    io.write((out or qerr) .. "\n")
    return out and 0 or 1
  end
end

--- Handle --benchmark flag.
local function handle_benchmark(spec: string): integer
  local benchmark = require("_tool.benchmark")
  local file_path = spec
  local filter: string = nil

  local colon_pos = spec:find(":[^/\\]")
  if colon_pos then
    file_path = spec:sub(1, colon_pos - 1)
    filter = spec:sub(colon_pos + 1)
  end

  local span = instrument.begin("benchmark", file_path)
  local result = benchmark.run(file_path, {filter = filter})
  io.write(benchmark.format_results(file_path, result) .. "\n")
  instrument.finish(span, result.exit_code)
  return result.exit_code
end

--- Handle --docs flag: exact lookup first, then search fallback.
local function handle_docs(query: string): integer
  local docs_mod = require("cosmic.doc")
  local out, qerr = docs_mod.query(query)
  if not out and query ~= "" then
    local docs = require("cosmic.doc")
    local results = docs.search(query)
    if #results > 0 then
      out = docs.render_search_results(results, query)
    end
  end
  if out then
    io.write(out .. "\n")
    return 0
  elseif query == "" then
    io.write((qerr or "error: no documentation found") .. "\n")
    return 1
  else
    io.stderr:write((qerr or "error: no documentation found") .. "\n")
    return 1
  end
end

--- Handle --check lint flag.
local function handle_check_style(file: string): integer
  local span = instrument.begin("check-style", file)
  local f = io.open(file, "r")
  if not f then
    io.stderr:write(file .. ": no such file\n")
    instrument.finish(span, 1)
    return 1
  end
  f:close()
  -- `_cli.lint` is the one entry point, so `--check lint` and
  -- `--make lint` cannot disagree about what the style gate is.
  local lint = require("_cli.lint")
  local found, lerr = lint.lint_file(file)
  if not found then
    io.stderr:write(file .. ": " .. (lerr or "cannot lint") .. "\n")
    instrument.finish(span, 1)
    return 1
  end
  local diagnostics = found
  if #diagnostics == 0 then
    io.write("Style check passed: " .. file .. "\n")
    instrument.finish(span, 0)
    return 0
  end
  local render = require("_cli.lint_render").render_diagnostics
  io.stderr:write(render(file, diagnostics))
  instrument.finish(span, 1)
  return 1
end

--- Handle --make flag: `--make <verb> [paths…]`. The verb owns its own
--- output and exit code (every verb ends in a verdict line), so this is
--- a straight delegation.
local function handle_make(argv: {string}): integer
  return require("_make").run(argv)
end

--- Refuse a run combining more than one of the file commands
--- (--format, --fix, --check). Leftover positionals carry no position,
--- so splitting them between two of these would guess which flag each
--- file was typed after — and a wrong guess REWRITES a file the user
--- only asked to check. True when the run was refused.
local function refuse_combined_file_commands(nformat: integer,
    nfix: integer, has_check: boolean): boolean
  local given = (nformat > 0 and 1 or 0) + (nfix > 0 and 1 or 0)
  + (has_check and 1 or 0)
  if given < 2 then return false end
  io.stderr:write("cosmic-lua: --format, --fix and --check are separate"
    .. " commands and cannot share one command line; run them one at a"
    .. " time\n")
  return true
end

local record HandlersModule
  generate_welcome: function(): string
  run_repl: function()
  load_script_file: function(script_path: string): function(...: any): any ... | nil, string
  handle_version: function(): integer
  handle_compile: function(file: string, output?: string, write_if_changed?: boolean, include_dirs?: {string}, strict?: boolean): integer, string
  handle_format: function(file: string, output?: string, write_if_changed?: boolean): integer, string
  handle_check_format: function(file: string): integer
  handle_check_types: function(file: string, include_dirs?: {string}): integer
  handle_check_style: function(file: string): integer
  handle_embed: function(paths: {string}, output: string, exe?: string): integer
  handle_extract: function(dir: string, exe?: string): integer
  handle_check_examples: function(file: string): integer
  handle_examples: function(module_name: string): integer
  handle_benchmark: function(spec: string): integer
  handle_docs: function(query: string): integer
  handle_make: function(argv: {string}): integer
  refuse_combined_file_commands: function(nformat: integer, nfix: integer, has_check: boolean): boolean
end

local M: HandlersModule = {
  generate_welcome = generate_welcome,
  run_repl = run_repl,
  load_script_file = load_script_file,
  handle_version = handle_version,
  handle_compile = handle_compile,
  handle_format = handle_format,
  handle_check_format = handle_check_format,
  handle_check_types = handle_check_types,
  handle_check_style = handle_check_style,
  handle_embed = handle_embed,
  handle_extract = handle_extract,
  handle_check_examples = handle_check_examples,
  handle_examples = handle_examples,
  handle_benchmark = handle_benchmark,
  handle_docs = handle_docs,
  handle_make = handle_make,
  refuse_combined_file_commands = refuse_combined_file_commands,
}

return M
