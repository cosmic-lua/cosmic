--- Teal compilation and type-checking.
--- --compile uses lax mode for permissive compilation.
--- --check uses strict mode for thorough type checking.

local tl = require("tl")

--- A compiler or type checker issue.
local record Issue
  file: string
  line: integer
  column: integer
  message: string
  severity: string -- "error" or "warning"
end

--- Options for compiling Teal to Lua.
local record CompileOpts
  include_dirs: {string}
  gen_target: string
  gen_compat: string
end

--- Options for type-checking Teal files.
local record CheckOpts
  include_dirs: {string}
end

--- Result from compiling a Teal file.
local record CompileResult
  ok: boolean
  code: string
  errors: {Issue}
end

--- Result from type-checking a Teal file.
local record CheckResult
  ok: boolean
  warnings: {Issue}
  errors: {Issue}
end

--- Get default include directories for cosmic type definitions.
--- Returns paths to bundled and local type definition directories.
--- @return {string} List of default include directory paths
local function get_default_include_dirs(): {string}
  return {
    "lib/types", -- Local cosmic types (development, takes precedence)
    "/zip/.lua/types", -- Bundled cosmic types (in binary)
    "/zip/.lua/teal-types", -- Bundled third-party types (in binary)
    "/zip/.tl", -- Bundled cosmic .tl source (for type checking)
  }
end

--- Error from the Teal compiler.
local record TlError
  msg: string
  filename: string
  y: integer
  x: integer
end

--- Result from Teal's process_string function.
local record TlResult
  syntax_errors: {TlError}
  type_errors: {TlError}
  warnings: {TlError}
  ast: any
end

--- Internal result from processing a Teal file.
local record ProcessResult
  tl_result: TlResult
  shebang: string
  error: Issue
end

--- Process a Teal file: read, setup paths, run tl.process_string.
--- Returns ProcessResult with tl_result on success, or error on failure.
--- @param input_path string Path to the Teal file to process
--- @param include_dirs {string} Directories to search for type definitions
--- @param lax boolean If true, use lax mode; if false, use strict mode
--- @return ProcessResult Processing result with tl_result or error
local function process_file(input_path: string, include_dirs: {string}, lax: boolean): ProcessResult
  local f, open_err = io.open(input_path, "r")
  if not f then
    return {
      error = {
        file = input_path,
        line = 0,
        column = 0,
        message = "cannot open file: " .. (open_err or "unknown error"),
        severity = "error",
      },
    }
  end
  local input = f:read("*a")
  f:close()

  -- Extract shebang if present (to preserve it in output)
  local shebang: string = nil
  if input:sub(1, 2) == "#!" then
    local newline_pos = input:find("\n")
    if newline_pos then
      shebang = input:sub(1, newline_pos)
    end
  end

  include_dirs = include_dirs or get_default_include_dirs()

  -- Add include dirs to package.path for teal's module resolution
  local saved_path = package.path
  for _, dir in ipairs(include_dirs) do
    package.path = package.path .. ";" .. dir .. "/?.d.tl"
    package.path = package.path .. ";" .. dir .. "/?/init.d.tl"
    package.path = package.path .. ";" .. dir .. "/?.tl"
    package.path = package.path .. ";" .. dir .. "/?/init.tl"
  end

  -- Prepend TL_PATH env var so callers don't need to pass include_dirs manually.
  -- If TL_PATH contains ;;, replace it with current package.path (Lua semantics:
  -- ;; in package.path expands to the default/existing path).
  local tl_path = os.getenv("TL_PATH")
  if tl_path then
    local before, after = tl_path:match("^(.-);;(.*)$")
    if before and after then
      package.path = before .. ";" .. package.path .. ";" .. after
    else
      package.path = tl_path .. ";" .. package.path
    end
  end

  local env = tl.init_env(lax)
  local ok, result_or_err, proc_err = pcall(tl.process_string, input, false, env, input_path)

  package.path = saved_path

  if not ok then
    return {
      error = {
        file = input_path,
        line = 0,
        column = 0,
        message = tostring(result_or_err),
        severity = "error",
      },
    }
  end
  local result = result_or_err as TlResult

  if not result then
    return {
      error = {
        file = input_path,
        line = 0,
        column = 0,
        message = proc_err or "processing failed",
        severity = "error",
      },
    }
  end

  return {tl_result = result, shebang = shebang}
end

--- Collect errors from tl result (syntax_errors and type_errors).
--- Converts Teal's error format to cosmic's Issue format.
--- @param result TlResult The result from tl.process_string
--- @param input_path string Path to the source file for error reporting
--- @return {Issue} List of issues converted from TlErrors
local function collect_errors(result: TlResult, input_path: string): {Issue}
  local errors: {Issue} = {}

  if result.syntax_errors then
    for _, e in ipairs(result.syntax_errors) do
      if e.msg then
        table.insert(errors, {
            file = e.filename or input_path,
            line = e.y or 0,
            column = e.x or 0,
            message = e.msg,
            severity = "error",
          })
      end
    end
  end

  if result.type_errors then
    for _, e in ipairs(result.type_errors) do
      if e.msg then
        table.insert(errors, {
            file = e.filename or input_path,
            line = e.y or 0,
            column = e.x or 0,
            message = e.msg,
            severity = "error",
          })
      end
    end
  end

  return errors
end

--- Merge caller-provided include directories with defaults.
--- Caller dirs come first (higher priority), followed by default dirs.
--- @param extra {string} Additional include directories from caller
--- @return {string} Merged list of include directories
local function merge_include_dirs(extra: {string}): {string}
  local defaults = get_default_include_dirs()
  if not extra or #extra == 0 then
    return defaults
  end
  local merged: {string} = {}
  for _, d in ipairs(extra) do
    merged[#merged + 1] = d
  end
  for _, d in ipairs(defaults) do
    merged[#merged + 1] = d
  end
  return merged
end

--- Compile a Teal file to Lua code.
--- Uses lax mode for permissive compilation. Preserves shebang if present.
--- @param input_path string Path to the Teal file to compile
--- @param opts CompileOpts Compilation options (include_dirs, gen_target, gen_compat)
--- @return CompileResult Result with ok status, generated Lua code, and any errors
local function compile(input_path: string, opts: CompileOpts): CompileResult
  opts = opts or {} as CompileOpts

  local dirs = merge_include_dirs(opts.include_dirs)
  local proc = process_file(input_path, dirs, true)
  if proc.error then
    return {ok = false, code = nil, errors = {proc.error}}
  end

  local errors = collect_errors(proc.tl_result, input_path)
  if #errors > 0 then
    return {ok = false, code = nil, errors = errors}
  end

  local gen_opts: {string: any} = {
    gen_target = opts.gen_target or "5.4",
    gen_compat = opts.gen_compat or "off",
  }
  local lua_code = tl.generate(proc.tl_result.ast, gen_opts)

  if proc.shebang then
    lua_code = proc.shebang .. lua_code
  end

  return {ok = true, code = lua_code, errors = {}}
end

--- Type-check a Teal file.
--- Uses strict mode for thorough type checking. Collects errors and warnings.
--- @param input_path string Path to the Teal file to check
--- @param opts CheckOpts Type-checking options (include_dirs)
--- @return CheckResult Result with ok status, warnings, and errors
local function check(input_path: string, opts: CheckOpts): CheckResult
  opts = opts or {} as CheckOpts

  local dirs = merge_include_dirs(opts.include_dirs)
  local proc = process_file(input_path, dirs, false)
  if proc.error then
    return {ok = false, warnings = {}, errors = {proc.error}}
  end

  local errors = collect_errors(proc.tl_result, input_path)

  local warnings: {Issue} = {}
  if proc.tl_result.warnings then
    for _, w in ipairs(proc.tl_result.warnings) do
      if w.msg then
        table.insert(warnings, {
            file = w.filename or input_path,
            line = w.y or 0,
            column = w.x or 0,
            message = w.msg,
            severity = "warning",
          })
      end
    end
  end

  return {ok = #errors == 0, warnings = warnings, errors = errors}
end

--- Format issues for human-readable output.
--- Creates formatted strings like "file.tl:10:5: error: message".
--- @param issues {Issue} List of issues to format
--- @return string Formatted issues, one per line
local function format_issues(issues: {Issue}): string
  local lines: {string} = {}
  for _, issue in ipairs(issues) do
    table.insert(lines, string.format("%s:%d:%d: %s: %s",
        issue.file,
        issue.line,
        issue.column,
        issue.severity,
        issue.message))
  end
  return table.concat(lines, "\n")
end

local record TealModule
  compile: function(input_path: string, opts?: CompileOpts): CompileResult
  check: function(input_path: string, opts?: CheckOpts): CheckResult
  format_issues: function(issues: {Issue}): string
  get_default_include_dirs: function(): {string}
end

local M: TealModule = {
  compile = compile,
  check = check,
  format_issues = format_issues,
  get_default_include_dirs = get_default_include_dirs,
}

return M
