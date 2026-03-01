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
    -- add bundled .tl source path so teal compiler can find cosmic modules
    package.path = package.path .. ";/zip/.tl/?.tl"
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

--- Write content to stdout or, with --write-if-changed and --output, atomically
--- to a file only when its content differs from what is already on disk.
local function write_output(content: string, output: string, write_if_changed: boolean): integer, string
  if not output or not write_if_changed then
    io.write(content)
    return 0
  end
  local cio = require("cosmic.io")
  local existing, _ = cio.slurp(output)
  if existing == content then
    return 0
  end
  local unix = require("cosmo.unix")
  local tmp_fd, tmp_path = unix.mkstemp(output .. ".XXXXXX")
  if not tmp_fd then
    return 1, "write-if-changed: mkstemp failed for: " .. output
  end
  unix.close(tmp_fd)
  local ok, err = cio.barf(tmp_path, content)
  if not ok then
    os.remove(tmp_path)
    return 1, "write-if-changed: failed to write tmp: " .. (err or "")
  end
  local fs = require("cosmic.fs")
  local rok, rerr = fs.rename(tmp_path, output)
  if not rok then
    os.remove(tmp_path)
    return 1, "write-if-changed: rename failed: " .. (rerr or "")
  end
  return 0
end

--- Handle --compile flag.
local function handle_compile(file: string, output?: string, write_if_changed?: boolean): integer, string
  local teal = require("cosmic.teal")
  local result = teal.compile(file)
  if result.ok then
    return write_output(result.code, output, write_if_changed)
  else
    io.stderr:write(teal.format_issues(result.errors) .. "\n")
    return 1
  end
end

--- Handle --format flag.
local function handle_format(file: string, output?: string, write_if_changed?: boolean): integer, string
  local fmt = require("cosmic.format")
  local result = fmt.format_file(file)
  if result.ok then
    return write_output(result.code, output, write_if_changed)
  else
    io.stderr:write(fmt.format_issues(result.errors) .. "\n")
    return 1
  end
end

--- Handle --check-format flag.
local function handle_check_format(file: string): integer
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
    io.write("Format check passed\n")
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
      io.stderr:write(string.format("%s:%d: format mismatch\n", file, i))
      io.stderr:write(string.format("  have: %s\n", orig_lines[i] or "<eof>"))
      io.stderr:write(string.format("  want: %s\n", fmt_lines[i] or "<eof>"))
      break
    end
  end
  return 1
end

--- Handle --check-types flag.
local function handle_check_types(file: string): integer
  local teal = require("cosmic.teal")
  local result = teal.check(file)

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

--- Handle --check-style flag.
local function handle_check_style(file: string): integer
  local f = io.open(file, "r")
  if not f then
    io.stderr:write(file .. ": no such file\n")
    return 1
  end
  f:close()
  local lint = require("cosmic.style")
  local diagnostics = lint.lint_file(file)
  if #diagnostics == 0 then
    io.write("Style check passed\n")
    return 0
  end
  for _, d in ipairs(diagnostics) do
    io.stderr:write(string.format("%s:%d:%d: %s: %s\n", d.file, d.line, d.col, d.rule, d.message))
  end
  return 1
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

--- Generate the SKILL.md content for --skill.
local function skill_content(): string
  return [=[---
name: cosmic
description: >
  Write portable scripts and tools with cosmic — HTTP requests, JSON
  parsing, SQLite databases, filesystem operations, child processes, crypto,
  compression, and more in a single zero-dependency binary
---

# cosmic

cosmic is a batteries-included Lua distribution for writing portable
scripts and tools. it ships as a single binary with built-in support for
HTTP fetching, JSON, SQLite, filesystem operations, child processes,
cryptographic hashing, compression, regex, sockets, and more — no external
dependencies needed. source files are written in Teal (typed Lua) and run
on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD.

## Download

the binary is named `cosmic` after download. rename it if you prefer.

```bash
curl -fLo cosmic \
  https://github.com/whilp/cosmic/releases/latest/download/cosmic-lua
chmod +x cosmic
```

## Run

```bash
./cosmic script.tl           # run a Teal script
./cosmic -e 'print("hi")'   # run inline code
./cosmic -i                  # start the REPL
```

## Getting Help

```bash
./cosmic --welcome                # quick-start orientation
./cosmic --help                   # show all CLI options and modules
./cosmic --docs                   # browse the full documentation index
./cosmic --docs <query>           # look up a module, function, or guide
./cosmic --docs guide             # list available guides
./cosmic --docs guide.testing     # show a specific guide
```
]=]
end

--- Handle --skill flag.
--- Creates the output directory and writes SKILL.md there.
local function handle_skill(dir: string): integer
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")

  local ok, err = fs.makedirs(dir)
  if not ok then
    io.stderr:write("--skill: " .. (err or "failed to create directory") .. "\n")
    return 1
  end

  local path = fs.join(dir, "SKILL.md")
  local wok, werr = cio.barf(path, skill_content())
  if not wok then
    io.stderr:write("--skill: " .. (werr or "failed to write SKILL.md") .. "\n")
    return 1
  end

  io.write(path .. "\n")
  return 0
end

local record HandlersModule
  generate_welcome: function(): string
  run_repl: function()
  load_script_file: function(script_path: string): function(...: any): any ..., string
  run_docs: function(query: string): DocsRunResult
  handle_version: function(): integer
  handle_compile: function(file: string, output?: string, write_if_changed?: boolean): integer, string
  handle_format: function(file: string, output?: string, write_if_changed?: boolean): integer, string
  handle_check_format: function(file: string): integer
  handle_check_types: function(file: string): integer
  handle_check_style: function(file: string): integer
  handle_embed: function(paths: {string}, output: string): integer
  handle_extract: function(dir: string): integer
  handle_check_examples: function(file: string): integer
  handle_examples: function(module_name: string): integer
  handle_benchmark: function(spec: string): integer
  handle_docs: function(query: string): integer
  handle_make: function(dir: string, target: string): integer
  handle_skill: function(dir: string): integer
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
  handle_check_style = handle_check_style,
  handle_embed = handle_embed,
  handle_extract = handle_extract,
  handle_check_examples = handle_check_examples,
  handle_examples = handle_examples,
  handle_benchmark = handle_benchmark,
  handle_docs = handle_docs,
  handle_make = handle_make,
  handle_skill = handle_skill,
}

return M
