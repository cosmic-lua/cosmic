--- Teal compilation and type-checking.
--- Both halves of rule 6 (#1001): `compile(source)`/`check(source)`
--- take Teal SOURCE, `compile_file(path)`/`check_file(path)` take a
--- path — the file variant wears the `_file` suffix instead of the
--- bare name. --compile uses lax mode for permissive compilation (the
--- gradual-typing on-ramp for plain-Lua scripts); --compile-strict
--- type-checks strictly (warnings fail, matching --check types) and
--- generates from the same checked AST — the build uses it for
--- in-tree sources so nothing ships that did not typecheck. --check
--- types uses strict mode.

-- This module must be absent exactly when the compiler is — a stripped
-- artifact asserts both fail together, and its searcher relies on that
-- to answer require misses without blaming tl (_make/artifact_test.tl).
-- But loading tl parses ~435KB of Lua that a warm-cache script run
-- never needs (#938). So: prove tl EXISTS at load time without loading
-- it, and require it only where it runs — package.loaded makes the
-- repeat cost one lookup.
if not package.loaded["tl"] and not package.preload["tl"]
and not package.searchpath("tl", package.path) then
  error("module 'tl' not found: cosmic.teal needs the Teal compiler", 0)
end

local engine = require("cosmic._teal_engine")

local type Issue = engine.Issue
local type CompileOptions = engine.CompileOptions
local type CheckOptions = engine.CheckOptions
local type CompileResult = engine.CompileResult
local type CheckResult = engine.CheckResult
local type ProcessResult = engine.ProcessResult

local DEFAULT_GEN_TARGET = engine.DEFAULT_GEN_TARGET

--- Finish a compile from a processed source: collect issues, apply the
--- strict gates, generate. Shared by the string and file halves.
local function finish_compile(proc: ProcessResult, name: string,
    opts: CompileOptions): CompileResult
  local tl = require("tl")
  if proc.error then
    return {ok = false, code = nil, errors = {proc.error}}
  end

  local errors = engine.collect_errors(proc.tl_result, name)
  if opts.strict and opts.werror ~= false then
    for _, w in ipairs(engine.collect_warnings(proc.tl_result, name)) do
      table.insert(errors, w)
    end
  end
  if opts.strict and #errors == 0 then
    engine.collect_discards(proc, name, errors)
  end
  if #errors > 0 then
    return {ok = false, code = nil, errors = errors}
  end

  -- tl.generate's second argument is the target STRING; passing an
  -- options table silently fell back to tl's default (non-5.4) target,
  -- which rejects 5.4-only syntax like <close> attributes. gen_compat
  -- was threaded into the env by the engine (tl.new_env rejects
  -- gen_target 5.4 with a non-"off" gen_compat), so both stay
  -- consistent here.
  local lua_code = tl.generate(proc.tl_result.ast, opts.gen_target or DEFAULT_GEN_TARGET)

  if proc.shebang then
    lua_code = proc.shebang .. lua_code
  end

  return {ok = true, code = lua_code, errors = {}}
end

--- Finish a check from a processed source. Shared by both halves.
local function finish_check(proc: ProcessResult, name: string,
    opts: CheckOptions): CheckResult
  local werror = opts.werror ~= false
  if proc.error then
    return {ok = false, warnings = {}, errors = {proc.error}}
  end

  local errors = engine.collect_errors(proc.tl_result, name)
  local warnings = engine.collect_warnings(proc.tl_result, name)
  if #errors == 0 then
    engine.collect_discards(proc, name, errors)
  end

  local ok = #errors == 0 and (not werror or #warnings == 0)
  return {ok = ok, warnings = warnings, errors = errors}
end

--- Compile Teal SOURCE to Lua code (#1001: the string half — the file
--- variant is compile_file). Lax mode by default (permissive, for user
--- scripts); opts.strict type-checks strictly first — warnings fail
--- too, matching check's default — and generates from that same
--- checked AST, so a strict compile can never ship code the checker
--- rejected. Preserves a leading shebang. Errors carry opts.chunk_name
--- (default "source") as their file.
--- @param source string The Teal source text
--- @param opts CompileOptions? Compilation options (include_dirs, gen_target, gen_compat, strict, chunk_name)
--- @return CompileResult Result with ok status, generated Lua code, and any errors
local function compile(source: string, opts?: CompileOptions): CompileResult
  opts = opts or {}
  local name = opts.chunk_name or "source"
  local dirs = engine.merge_include_dirs(opts.include_dirs)
  local proc = engine.process_source(source, name, dirs, not opts.strict,
    opts.gen_target, opts.gen_compat)
  return finish_compile(proc, name, opts)
end

--- Compile a Teal file to Lua code (#1001: was `compile`).
--- Same contract as compile; the path names the errors.
--- @param input_path string Path to the Teal file to compile
--- @param opts CompileOptions? Compilation options (include_dirs, gen_target, gen_compat, strict)
--- @return CompileResult Result with ok status, generated Lua code, and any errors
local function compile_file(input_path: string, opts?: CompileOptions): CompileResult
  opts = opts or {}
  local dirs = engine.merge_include_dirs(opts.include_dirs)
  local proc = engine.process_file(input_path, dirs, not opts.strict,
    opts.gen_target, opts.gen_compat)
  return finish_compile(proc, input_path, opts)
end

--- Type-check Teal SOURCE (#1001: the string half — the file variant
--- is check_file). Uses strict mode. Warnings fail the check
--- (ok = false) unless opts.werror is explicitly false: an unused
--- local or shadowed variable is a defect the author must either fix
--- or deliberately mark (leading underscore), never ignore. Errors
--- carry opts.chunk_name (default "source") as their file.
--- @param source string The Teal source text
--- @param opts CheckOptions? Type-checking options (include_dirs, werror, chunk_name)
--- @return CheckResult Result with ok status, warnings, and errors
local function check(source: string, opts?: CheckOptions): CheckResult
  opts = opts or {}
  local name = opts.chunk_name or "source"
  local dirs = engine.merge_include_dirs(opts.include_dirs)
  local proc = engine.process_source(source, name, dirs, false)
  return finish_check(proc, name, opts)
end

--- Type-check a Teal file (#1001: was `check`).
--- Same contract as check; the path names the errors.
--- @param input_path string Path to the Teal file to check
--- @param opts CheckOptions? Type-checking options (include_dirs, werror)
--- @return CheckResult Result with ok status, warnings, and errors
local function check_file(input_path: string, opts?: CheckOptions): CheckResult
  opts = opts or {}
  local dirs = engine.merge_include_dirs(opts.include_dirs)
  local proc = engine.process_file(input_path, dirs, false)
  return finish_check(proc, input_path, opts)
end

--- Find the source file for a module name using the same search path
--- the compiler uses (TL_PATH, include dirs, package.path). Used by the
--- runtime .tl searcher so require() resolves modules exactly like
--- --compile/--check types do.
--- @param module_name string Module name as passed to require()
--- @param include_dirs? {string} Extra include dirs (defaults merged in)
--- @return string|nil Path to the found source, or nil
local function search_module(module_name: string, include_dirs?: {string}): string | nil
  local tl = require("tl")
  local dirs = engine.merge_include_dirs(include_dirs)
  local saved_tl_path = tl.path
  tl.path = engine.assemble_tl_path(dirs)
  local found, fd = tl.search_module(module_name, false)
  tl.path = saved_tl_path
  if fd ~= nil then
    local f = fd as FILE -- cast: from any
    f:close()
  end
  return found
end

-- The hint patterns live in their own module for room; the pattern set
-- is the part that grows.
local hint_for_message = require("cosmic._teal_hints").hint_for_message

--- Options for format_issues.
local record FormatOptions
  --- Append one fix-hint line after each error matching a known Teal
  --- type-check trap (#1001: was the format_issues_with_hints variant —
  --- a `_with_X` suffix is an options field).
  hints: boolean
end

--- Format issues for human-readable output.
--- Creates formatted strings like "file.tl:10:5: error: message";
--- opts.hints appends a fix-hint line after each recognized error.
--- @param issues {Issue} List of issues to format
--- @param opts FormatOptions? hints: append fix-hints for known traps
--- @return string Formatted issues, one per line (plus hint lines)
local function format_issues(issues: {Issue}, opts?: FormatOptions): string
  local lines: {string} = {}
  for _, issue in ipairs(issues) do
    table.insert(lines, string.format("%s:%d:%d: %s: %s",
        issue.file,
        issue.line,
        issue.column,
        issue.severity,
        issue.message))
    if opts and opts.hints then
      local hint = hint_for_message(issue.message)
      if hint then
        table.insert(lines, hint)
      end
    end
  end
  return table.concat(lines, "\n")
end

--- Options for compile_cached.
local record CacheOptions
  --- Type-check strictly (warnings still pass), like CompileOptions.
  strict: boolean
end

--- Compile a Teal file, reusing cached output when the source has not
--- changed. Lax, like `compile_file`; `check_file` remains the strict
--- gate.
---
--- The loop itself lives with the cache it drives (`cosmic._script_cache`);
--- this is the name its two callers know it by.
--- @param input_path string Path to the Teal file to compile
--- @param opts CacheOptions? strict: type-check strictly (warnings still pass)
--- @return string|nil The generated Lua code, or nil when compilation failed
--- @return string The formatted issues when compilation failed
local function compile_cached(input_path: string,
    opts?: CacheOptions): string | nil, string
  local strict = opts and opts.strict or false
  return require("cosmic._script_cache").compile_cached(input_path, strict)
end

local record TealModule
  --- Exported so callers can name options and results; type aliases,
  --- not runtime values.
  type Issue = Issue
  type CompileOptions = CompileOptions
  type CheckOptions = CheckOptions
  type CompileResult = CompileResult
  type CheckResult = CheckResult
  type FormatOptions = FormatOptions
  type CacheOptions = CacheOptions

  DEFAULT_GEN_TARGET: string
  DEFAULT_GEN_COMPAT: string
  BUILD_INCLUDE_DIRS: {string}
  compile: function(source: string, opts?: CompileOptions): CompileResult
  compile_file: function(input_path: string, opts?: CompileOptions): CompileResult
  compile_cached: function(input_path: string, opts?: CacheOptions): string | nil, string
  check: function(source: string, opts?: CheckOptions): CheckResult
  check_file: function(input_path: string, opts?: CheckOptions): CheckResult
  search_module: function(module_name: string, include_dirs?: {string}): string | nil
  format_issues: function(issues: {Issue}, opts?: FormatOptions): string
  hint_for_message: function(msg: string): string | nil
  default_include_dirs: function(): {string}
end

local M: TealModule = {
  DEFAULT_GEN_TARGET = engine.DEFAULT_GEN_TARGET,
  DEFAULT_GEN_COMPAT = engine.DEFAULT_GEN_COMPAT,
  BUILD_INCLUDE_DIRS = engine.BUILD_INCLUDE_DIRS,
  compile = compile,
  compile_file = compile_file,
  compile_cached = compile_cached,
  check = check,
  check_file = check_file,
  search_module = search_module,
  format_issues = format_issues,
  hint_for_message = hint_for_message,
  default_include_dirs = engine.default_include_dirs,
}

return M
