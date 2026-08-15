--- The compile/check engine under cosmic.teal: the shared records,
--- the include-dir plumbing, and the process/collect passes both the
--- file and string halves finish from. A flat `_teal_engine` sibling
--- like `_teal_hints`/`_teal_ast`/`_teal_discard` rather than a
--- cosmic/teal/ directory module: a directory rename would leave a
--- stale flat `teal.lua` shadowing the new init in any cached `o/`
--- (`?.lua` beats `?/init.lua`). The public surface is cosmic.teal's.

--- A compiler or type checker issue.
local record Issue
  file: string
  line: integer
  column: integer
  message: string
  severity: string -- "error" or "warning"
  tag: string -- warning kind ("unused", "redeclaration", ...) when severity is "warning"
end

--- Options for compiling Teal to Lua.
--- strict type-checks strictly before generating (warnings fail too,
--- matching check's default) and emits code from that same checked AST.
--- werror = false keeps the strict type check and lets warnings pass:
--- the runtime in-project searcher wants the checking, not the style
--- gate. See `cosmic.searcher`.
local record CompileOptions
  include_dirs: {string}
  gen_target: string
  gen_compat: string
  strict: boolean
  werror: boolean
  --- Name the STRING half's errors carry (compile(source) has no path);
  --- default "source". The file half ignores it — the path is the name.
  chunk_name: string
end

--- Options for type-checking Teal.
--- Warnings fail the check unless werror is explicitly set to false.
local record CheckOptions
  include_dirs: {string}
  werror: boolean
  --- Name the STRING half's errors carry; default "source".
  chunk_name: string
end

--- Result from compiling Teal. `code` is nil when ok is
--- false — the type says so instead of forcing a cast at every
--- consumer.
local record CompileResult
  ok: boolean
  code: string | nil
  errors: {Issue}
end

--- Result from type-checking Teal.
local record CheckResult
  ok: boolean
  warnings: {Issue}
  errors: {Issue}
end

--- Generation defaults shared by every compile path. tlconfig.lua
--- mirrors these for editor/LSP tooling; teal_config_test.tl fails if
--- the mirror drifts.
local DEFAULT_GEN_TARGET < const > = "5.4"
local DEFAULT_GEN_COMPAT < const > = "off"

--- Extra include dirs the build passes via `--include-dir`.
--- `embed/cosmic.mk`'s compile rule and tlconfig.lua both mirror this
--- list; teal_config_test.tl fails if either drifts, so the build, the
--- checker, and the editor resolve types identically.
local BUILD_INCLUDE_DIRS < const >: {string} = {"."}

--- Get default include directories for cosmic type definitions.
--- Returns paths to bundled and local type definition directories.
--- @return {string} List of default include directory paths
local function default_include_dirs(): {string}
  return {
    -- Generated, not committed: `_types/types_gen.tl` writes them here
    -- before any graph verb runs -- a generation unit owns
    -- `o/<its path minus .tl>/`. Development copy takes precedence.
    "o/_types/types_gen",
    "/zip/.types", -- Bundled cosmic types (in binary)
    "/zip/.tl", -- Bundled cosmic .tl source (for type checking)
    "/zip", -- The app's own zip root: embedded modules beside main.lua
  }
end

--- Assemble the tl module-search path from TL_PATH + include dirs +
--- package.path, so tl.search_module finds all required modules
--- regardless of whether TL_PATH is set. tl.search_module priority:
--- TL_PATH env > tl.path > package.path. By putting include_dirs in
--- tl.path (which takes precedence over package.path), they are always
--- consulted — even when TL_PATH is set. Appending package.path
--- preserves CWD-relative and system search patterns.
--- @param include_dirs {string} Directories to search for modules/types
--- @return string The assembled search path for tl.path
local function assemble_tl_path(include_dirs: {string}): string
  local path_parts: {string} = {}
  local tl_path = os.getenv("TL_PATH")
  if tl_path then
    path_parts[#path_parts + 1] = tl_path
  end
  for _, dir in ipairs(include_dirs) do
    path_parts[#path_parts + 1] = dir .. "/?.d.tl"
    path_parts[#path_parts + 1] = dir .. "/?/init.d.tl"
    path_parts[#path_parts + 1] = dir .. "/?.tl"
    path_parts[#path_parts + 1] = dir .. "/?/init.tl"
  end
  path_parts[#path_parts + 1] = package.path
  return table.concat(path_parts, ";")
end

--- Error from the Teal compiler.
local record TlError
  msg: string
  filename: string
  y: integer
  x: integer
  tag: string
end

--- Result from Teal's process_string function.
local record TlResult
  syntax_errors: {TlError}
  type_errors: {TlError}
  warnings: {TlError}
  ast: any
end

--- Internal result from processing Teal source.
local record ProcessResult
  tl_result: TlResult
  shebang: string
  error: Issue
  --- The tl env the source ran in; strict runs collect a typed position
  --- report on it for the discarded-error pass.
  env: any
end

--- Build a ProcessResult carrying a single top-of-file error.
local function process_error(name: string, message: string): ProcessResult
  return {error = {file = name, line = 0, column = 0, message = message, severity = "error"}}
end

-- Envs are reused across calls: construction costs ~6 ms per
-- call even with the pre-parsed stdlib ASTs (thaw plus tl re-checking
-- its stdlib), so one env per option set makes the second and later
-- checks in a process pay only their marginal cost. Everything that
-- shapes an env goes in the key — lax, target, compat, and the
-- assembled tl.path, because a reused env caches required modules
-- resolved through it. Like tl's own project mode, a reused env
-- accumulates checked-module state across calls; within one process
-- that accumulation is exactly the amortization, and sources do not
-- change mid-process.
local env_cache: {string: any} = {}

--- Construct a fresh env for the given options (report_types on for
--- strict, matching what the discarded-error pass reads).
--- @param lax boolean If true, lax mode; if false, strict mode
--- @param gen_target string Codegen target
--- @param gen_compat string Compat shims
--- @return any The env, or nil on failure
--- @return string? Error message on failure
local function build_env(lax: boolean, gen_target: string, gen_compat: string): any, string
  local env, env_err = require("cosmic._teal_ast").new_env({
      feat_lax = lax and "on" or "off",
      feat_arity = "on",
      gen_target = gen_target,
      gen_compat = gen_compat,
    })
  if not env then
    return nil, env_err
  end
  if not lax then
    local env_map = env as {any: any} -- cast: beyond the narrowed API
    env_map["report_types"] = true
  end
  return env
end

--- Process Teal SOURCE: setup paths, run tl.process_string. The engine
--- both halves share: the file half reads and delegates here.
--- @param input string The Teal source text
--- @param name string What errors call this source (a path, or a chunk name)
--- @param include_dirs {string} Directories to search for type definitions
--- @param lax boolean If true, use lax mode; if false, use strict mode
--- @param gen_target? string Codegen target ("5.1"|"5.3"|"5.4"), default DEFAULT_GEN_TARGET
--- @param gen_compat? string Compat shims ("off"|"optional"|"required"), default DEFAULT_GEN_COMPAT
--- @return ProcessResult Processing result with tl_result or error
local function process_source(input: string, name: string, include_dirs: {string},
    lax: boolean, gen_target?: string, gen_compat?: string): ProcessResult
  local tl = require("tl")

  -- Extract shebang if present (to preserve it in output)
  local shebang: string = nil
  if input:sub(1, 2) == "#!" then
    local newline_pos = input:find("\n")
    if newline_pos then
      shebang = input:sub(1, newline_pos)
    end
  end

  include_dirs = include_dirs or default_include_dirs()

  local tl_path = assemble_tl_path(include_dirs)
  local saved_tl_path = tl.path
  tl.path = tl_path

  -- Options-form env construction: feature flags are explicit rather than
  -- inherited from tl's version-dependent defaults. feat_arity stays "on"
  -- (0.24 default) so function-arity mismatches are checked in strict mode.
  -- The env rides the artifact's pre-parsed stdlib ASTs when present
  -- (cosmic._teal_ast), skipping tl's parse of its embedded d.tl sources.
  local use_target = gen_target or DEFAULT_GEN_TARGET
  local use_compat = gen_compat or DEFAULT_GEN_COMPAT
  local cache_key = table.concat(
    {lax and "lax" or "strict", use_target, use_compat, tl_path}, "\0")
  local env: any = env_cache[cache_key]
  if env == nil then
    local fresh, env_err = build_env(lax, use_target, use_compat)
    if not fresh then
      tl.path = saved_tl_path
      return process_error(name, "tl.new_env: " .. (env_err or "unknown error"))
    end
    env_cache[cache_key] = fresh
    env = fresh
  else
    -- A reused env remembers results by chunk name (tl.check_string
    -- returns env.loaded[filename] when present); evict this name so a
    -- re-check checks the source in hand, not the remembered one.
    local env_map = env as {any: any} -- cast: beyond the narrowed API
    local loaded = env_map["loaded"] as {any: any} -- cast: beyond the narrowed API
    if loaded then
      loaded[name] = nil
    end
  end
  -- process_string returns exactly one value (a Result); errors land in
  -- its syntax_errors/type_errors fields or arrive here as a throw.
  local ok, result_or_err = pcall(tl.process_string, input, false, env, name)

  tl.path = saved_tl_path

  if not ok then
    -- A throw may leave the env half-mutated; rebuild it next call.
    env_cache[cache_key] = nil
    return process_error(name, tostring(result_or_err))
  end
  local result = result_or_err as TlResult -- cast: from any

  if not result then
    return process_error(name, "processing failed")
  end

  return {tl_result = result, shebang = shebang, env = env}
end

--- Process a Teal file: read it, then process_source.
--- @param input_path string Path to the Teal file to process
--- @param include_dirs {string} Directories to search for type definitions
--- @param lax boolean If true, use lax mode; if false, use strict mode
--- @param gen_target? string Codegen target, default DEFAULT_GEN_TARGET
--- @param gen_compat? string Compat shims, default DEFAULT_GEN_COMPAT
--- @return ProcessResult Processing result with tl_result or error
local function process_file(input_path: string, include_dirs: {string}, lax: boolean,
    gen_target?: string, gen_compat?: string): ProcessResult
  local f, open_err = io.open(input_path, "r")
  if not f then
    return process_error(input_path, "cannot open file: " .. (open_err or "unknown error"))
  end
  local input = f:read("*a")
  f:close()
  return process_source(input, input_path, include_dirs, lax, gen_target, gen_compat)
end

--- Collect errors from tl result (syntax_errors and type_errors).
--- Converts Teal's error format to cosmic's Issue format.
--- @param result TlResult The result from tl.process_string
--- @param name string Source name for error reporting
--- @return {Issue} List of issues converted from TlErrors
local function collect_errors(result: TlResult, name: string): {Issue}
  local errors: {Issue} = {}

  if result.syntax_errors then
    for _, e in ipairs(result.syntax_errors) do
      if e.msg then
        table.insert(errors, {
            file = e.filename or name,
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
            file = e.filename or name,
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

--- Collect warnings from a tl result as Issue records.
--- @param result TlResult The result from tl.process_string
--- @param name string Source name for error reporting
--- @return {Issue} List of warning issues
local function collect_warnings(result: TlResult, name: string): {Issue}
  local warnings: {Issue} = {}
  if result.warnings then
    for _, w in ipairs(result.warnings) do
      if w.msg then
        table.insert(warnings, {
            file = w.filename or name,
            line = w.y or 0,
            column = w.x or 0,
            message = w.msg,
            severity = "warning",
            tag = w.tag,
          })
      end
    end
  end
  return warnings
end

--- Append discarded-error findings (cosmic._teal_discard) as error
--- Issues; strict-only, required lazily so lax compiles never load it.
local function collect_discards(proc: ProcessResult, name: string,
    errors: {Issue})
  local discard = require("cosmic._teal_discard")
  for _, d in ipairs(discard.issues(proc.env, proc.tl_result.ast, name)) do
    table.insert(errors, {file = d.file, line = d.line, column = d.column,
        message = d.message, severity = "error"})
  end
end

--- Merge caller-provided include directories with defaults.
--- Caller dirs come first (higher priority), followed by default dirs.
--- @param extra {string} Additional include directories from caller
--- @return {string} Merged list of include directories
local function merge_include_dirs(extra: {string}): {string}
  local defaults = default_include_dirs()
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

local record EngineModule
  type Issue = Issue
  type CompileOptions = CompileOptions
  type CheckOptions = CheckOptions
  type CompileResult = CompileResult
  type CheckResult = CheckResult
  type TlError = TlError
  type TlResult = TlResult
  type ProcessResult = ProcessResult

  DEFAULT_GEN_TARGET: string
  DEFAULT_GEN_COMPAT: string
  BUILD_INCLUDE_DIRS: {string}
  default_include_dirs: function(): {string}
  assemble_tl_path: function(include_dirs: {string}): string
  process_source: function(input: string, name: string, include_dirs: {string}, lax: boolean, gen_target?: string, gen_compat?: string): ProcessResult
  process_file: function(input_path: string, include_dirs: {string}, lax: boolean, gen_target?: string, gen_compat?: string): ProcessResult
  collect_errors: function(result: TlResult, name: string): {Issue}
  collect_warnings: function(result: TlResult, name: string): {Issue}
  collect_discards: function(proc: ProcessResult, name: string, errors: {Issue})
  merge_include_dirs: function(extra: {string}): {string}
end

local M: EngineModule = {
  DEFAULT_GEN_TARGET = DEFAULT_GEN_TARGET,
  DEFAULT_GEN_COMPAT = DEFAULT_GEN_COMPAT,
  BUILD_INCLUDE_DIRS = BUILD_INCLUDE_DIRS,
  default_include_dirs = default_include_dirs,
  assemble_tl_path = assemble_tl_path,
  process_source = process_source,
  process_file = process_file,
  collect_errors = collect_errors,
  collect_warnings = collect_warnings,
  collect_discards = collect_discards,
  merge_include_dirs = merge_include_dirs,
}

return M
