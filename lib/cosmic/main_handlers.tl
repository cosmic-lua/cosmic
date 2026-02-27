--- Command handler functions for the cosmic CLI.
--- Each handler implements one CLI command flag.

--- Result from running docs command.
local record DocsRunResult
  ok: boolean
  output: string
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

--- Interactive REPL using cosmopolitan's linenoise-based REPL.
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

--- Load a script file (.tl or .lua).
--- Compiles .tl files through Teal, loads .lua files directly.
local function load_script_file(script_path: string): function(...: any): any ..., string
  if script_path:match("%.tl$") then
    local teal = require("cosmic.teal")
    local result = teal.compile(script_path)
    if not result.ok then
      return nil, teal.format_issues(result.errors)
    end
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

--- Run docs command with smart matching.
--- @param query string The query string
--- @return DocsRunResult Result with ok status and output text
local function run_docs(query: string): DocsRunResult
  local docs = require("cosmic.docs")

  local result = docs.run(query)
  if result.ok then
    return {ok = true, output = result.output}
  end

  local results = docs.search(query)
  if #results > 0 then
    return {ok = true, output = docs.render_search_results(results, query)}
  end

  return {ok = false, output = result.output}
end

--- Handle --version flag.
local function handle_version(): integer
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

--- Write content to output, applying write-if-changed when path is given.
--- If path is nil or empty, writes to stdout.
--- If write_if_changed is true and path is given, only replaces the file
--- when content differs from what is already on disk.
--- @param path string Target file path (nil or "" for stdout)
--- @param content string Content to write
--- @param write_if_changed boolean Only write when content differs
--- @return integer Exit code (0 on success)
local function write_output(path: string, content: string, write_if_changed: boolean): integer
  if not path or path == "" then
    io.write(content)
    return 0
  end
  local tmp = path .. ".tmp"
  local cio = require("cosmic.io")
  local ok, err = cio.barf(tmp, content)
  if not ok then
    io.stderr:write("write-if-changed: " .. (err or "write error") .. "\n")
    return 1
  end
  if write_if_changed then
    local existing = cio.slurp(path)
    if existing == content then
      os.remove(tmp)
      return 0
    end
  end
  local renamed, rename_err = os.rename(tmp, path)
  if not renamed then
    io.stderr:write("write-if-changed: rename failed: " .. (rename_err or "unknown error") .. "\n")
    return 1
  end
  return 0
end

--- Handle --compile flag.
local function handle_compile(file: string, output: string, write_if_changed: boolean): integer
  local teal = require("cosmic.teal")
  local result = teal.compile(file)
  if result.ok then
    return write_output(output, result.code, write_if_changed)
  else
    io.stderr:write(teal.format_issues(result.errors) .. "\n")
    return 1
  end
end

--- Handle --format flag.
local function handle_format(file: string): integer
  local fmt = require("cosmic.format")
  local result = fmt.format_file(file)
  if result.ok then
    io.write(result.code)
    return 0
  else
    io.stderr:write(fmt.format_issues(result.errors) .. "\n")
    return 1
  end
end

--- Handle --check-format flag.
local function handle_check_format(file: string, output: string, write_if_changed: boolean): integer
  local fmt = require("cosmic.format")
  local result = fmt.format_file(file)
  if not result.ok then
    io.stderr:write(fmt.format_issues(result.errors) .. "\n")
    return 1
  end

  local cio = require("cosmic.io")
  local original, read_err = cio.slurp(file)
  if not original then
    io.stderr:write(file .. ": " .. (read_err or "unknown error") .. "\n")
    return 1
  end

  if original == result.code then
    return write_output(output, "Format check passed\n", write_if_changed)
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
      io.stderr:write(string.format("%s:%d: format mismatch\n", file, i))
      io.stderr:write(string.format("  have: %s\n", orig_lines[i] or "<eof>"))
      io.stderr:write(string.format("  want: %s\n", fmt_lines[i] or "<eof>"))
      break
    end
  end
  return 1
end

--- Handle --check-types flag.
local function handle_check_types(file: string, output: string, write_if_changed: boolean): integer
  local teal = require("cosmic.teal")
  local result = teal.check(file)

  if #result.warnings > 0 then
    io.stderr:write(teal.format_issues(result.warnings) .. "\n")
  end
  if #result.errors > 0 then
    io.stderr:write(teal.format_issues(result.errors) .. "\n")
  end

  if result.ok then
    return write_output(output, "Type check passed\n", write_if_changed)
  else
    return 1
  end
end

--- Handle --embed flag.
local function handle_embed(paths: {string}, output: string): integer
  local embed = require("cosmic.embed")
  local result = embed.run(paths, output)
  io.write(result.message .. "\n")
  return result.ok and 0 or 1
end

--- Handle --extract flag.
local function handle_extract(dir: string): integer
  local embed = require("cosmic.embed")
  local result = embed.extract(dir)
  io.write(result.message .. "\n")
  return result.ok and 0 or 1
end

--- Handle --check-examples flag.
local function handle_check_examples(file: string): integer
  local example = require("cosmic.example")
  local result = example.run(file)
  io.write(example.format_results(file, result) .. "\n")
  return result.exit_code
end

--- Handle --examples flag.
local function handle_examples(module_name: string): integer
  local docs = require("cosmic.docs")

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

--- Handle --benchmark flag.
local function handle_benchmark(spec: string): integer
  local benchmark = require("cosmic.benchmark")
  local file_path = spec
  local filter: string = nil

  local colon_pos = spec:find(":[^/\\]")
  if colon_pos then
    file_path = spec:sub(1, colon_pos - 1)
    filter = spec:sub(colon_pos + 1)
  end

  local result = benchmark.run(file_path, filter)
  io.write(benchmark.format_results(file_path, result) .. "\n")
  return result.exit_code
end

--- Handle --docs flag.
local function handle_docs(query: string): integer
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

--- Handle --make flag.
local function handle_make(dir: string, target: string): integer
  local mk = require("cosmic.make")
  local ok, result = mk.run(dir ~= "" and dir or nil, target)
  if ok then
    return 0
  else
    io.stderr:write((result or "make execution failed") .. "\n")
    return 1
  end
end

local record HandlersModule
  generate_welcome: function(): string
  run_repl: function()
  load_script_file: function(script_path: string): function(...: any): any ..., string
  run_docs: function(query: string): DocsRunResult
  handle_version: function(): integer
  handle_compile: function(file: string, output: string, write_if_changed: boolean): integer
  handle_format: function(file: string): integer
  handle_check_format: function(file: string, output: string, write_if_changed: boolean): integer
  handle_check_types: function(file: string, output: string, write_if_changed: boolean): integer
  handle_embed: function(paths: {string}, output: string): integer
  handle_extract: function(dir: string): integer
  handle_check_examples: function(file: string): integer
  handle_examples: function(module_name: string): integer
  handle_benchmark: function(spec: string): integer
  handle_docs: function(query: string): integer
  handle_make: function(dir: string, target: string): integer
end

local M: HandlersModule = {
  generate_welcome = generate_welcome,
  run_repl = run_repl,
  load_script_file = load_script_file,
  run_docs = run_docs,
  handle_version = handle_version,
  handle_compile = handle_compile,
  handle_format = handle_format,
  handle_check_format = handle_check_format,
  handle_check_types = handle_check_types,
  handle_embed = handle_embed,
  handle_extract = handle_extract,
  handle_check_examples = handle_check_examples,
  handle_examples = handle_examples,
  handle_benchmark = handle_benchmark,
  handle_docs = handle_docs,
  handle_make = handle_make,
}

return M
