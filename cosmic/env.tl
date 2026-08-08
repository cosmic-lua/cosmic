--- Environment variable utilities.
--- Reading, setting, and listing environment variables — env.get()
--- returns nil when the variable is not set, so the caller narrows;
--- env.get_or() takes a fallback and cannot fail — plus the dotenv
--- half (#994: was cosmic.envd): parse_dotenv/format_dotenv for the
--- KEY=VALUE text format, expand for ${VAR} references, and
--- load_dotenv/load_embedded_dotenv to apply a directory of dotenv
--- files to the process environment.
---
--- Dotenv format: each line is a KEY=VALUE assignment or a comment
--- (lines starting with #); blank lines are skipped. Keys must match
--- [A-Za-z_][A-Za-z0-9_]*. Values are taken as-is after the first =
--- (no trimming, no quote stripping) and support ${VAR} expansion:
---   ${VAR}            expands to the value of VAR
---   ${VAR:-default}   expands to default if VAR is unset or empty
---   ${VAR-default}    expands to default if VAR is unset
--- Variables defined earlier in the same file or in earlier files
--- (lexical order) are available for expansion, as are existing
--- environment variables. Undefined variables with no default expand
--- to the empty string.
---
--- The load half follows the dotenv convention for embedding
--- credentials (API keys, tokens) into a cosmic executable:
---
---   mkdir env.d
---   echo 'ANTHROPIC_API_KEY=sk-ant-...' > env.d/api
---   cosmic --embed env.d
---
--- At startup, call env.load_embedded_dotenv() to read
--- /zip/embed/env.d/ and set any variables not already present in the
--- environment; the real environment always takes precedence. Set
--- COSMIC_DEBUG=1 to see which vars are loaded and which are skipped.
-- The loader half sits on cosmo.* directly rather than cosmic.fs:
-- this module is on the pinned engine's own boot path (instrument
-- requires it), so at cold start it must compile against the PIN's
-- types — and the cosmo bindings are the surface that is stable
-- across generations, where cosmic.fs's record is not.
local cosmo = require("cosmo")
local cpath = require("cosmo.path")
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").wrap

--- Get the value of an environment variable, or nil when it is not set.
---
--- **The nil is in the type**, which is the whole point of this
--- function's shape. An optional default with a bare `string` return
--- is a lie the checker cannot see: with no default the body returns
--- the parameter, which is `string` inside the function and nil at the
--- call site, so `local v: string = env.get("X")` type-checks strictly
--- and crashes on the next line. A reading that can fail says so, and
--- the caller narrows -- see `get_or` for the half that cannot fail.
--- @param name string The name of the environment variable
--- @return string|nil The value, or nil when the variable is not set
local function get(name: string): string | nil
  return os.getenv(name)
end

--- Get the value of an environment variable, or `default` when unset.
---
--- The infallible half, and it is a separate function rather than an
--- optional argument because the two have genuinely different types: a
--- read with a fallback CANNOT fail, so making its caller narrow would
--- be noise, and folding both into one signature is what produced a
--- return type that was wrong half the time.
--- @param name string The name of the environment variable
--- @param default string The value to return when it is not set
--- @return string The value, or `default`
local function get_or(name: string, default: string): string
  local value = os.getenv(name)
  if value == nil then
    return default
  end
  return value
end

--- Set an environment variable.
--- @param name string The name of the environment variable
--- @param value string The value to set
--- @param overwrite? boolean If false, won't overwrite existing variables (defaults to true)
--- @return boolean True on success
--- @return string? Error message if setting failed
local function set(name: string, value: string, overwrite?: boolean): boolean, string
  local ok, err = unix.setenv(name, value, overwrite)
  if not ok then
    return false, errstr(err, "setenv " .. name)
  end
  return true
end

--- Unset an environment variable.
--- @param name string The name of the environment variable to remove
--- @return boolean True on success
--- @return string? Error message if unsetting failed
local function unset(name: string): boolean, string
  local ok, err = unix.unsetenv(name)
  if not ok then
    return false, errstr(err, "unsetenv " .. name)
  end
  return true
end

--- Get all environment variables.
--- Returns a table mapping variable names to their values.
--- @return {string:string} A table of all environment variables
local function all(): {string: string}
  local entries = unix.environ()
  local result: {string: string} = {}
  for _, entry in ipairs(entries) do
    local eq = entry:find("=", 1, true)
    if eq then
      result[entry:sub(1, eq - 1)] = entry:sub(eq + 1)
    end
  end
  return result
end

--- Options for list(): edits applied to the current environment.
local record ListOptions
  --- variable names to remove
  drop: {string}
  --- names to set or override; applied after drop, appended in
  --- sorted-name order so the result is deterministic
  set: {string: string}
end

--- Get the environment as a list of "KEY=VALUE" strings, optionally
--- edited — the shape `child.Options.env` and execve take. This is
--- the one place to build "the current environment, minus these
--- variables, plus those" instead of hand-rolling a filter loop:
---   env.list({drop = {"LUA_PATH"}, set = {NO_COLOR = "1"}})
--- @param opts ListOptions? drop: names to remove; set: names to set/override
--- @return {string} A list of "KEY=VALUE" strings
local function list(opts?: ListOptions): {string}
  local drop: {string: boolean} = {}
  if opts and opts.drop then
    for _, name in ipairs(opts.drop) do
      drop[name] = true
    end
  end
  local override = opts and opts.set
  local result: {string} = {}
  local seen: {string: integer} = {}
  for _, entry in ipairs(unix.environ()) do
    local eq = entry:find("=", 1, true)
    local name = eq and entry:sub(1, eq - 1) or entry
    if not drop[name] then
      if override and override[name] ~= nil then
        entry = name .. "=" .. override[name]
      end
      result[#result + 1] = entry
      seen[name] = #result
    end
  end
  if override then
    local missing: {string} = {}
    for name in pairs(override) do
      if not seen[name] then
        missing[#missing + 1] = name
      end
    end
    table.sort(missing)
    for _, name in ipairs(missing) do
      result[#result + 1] = name .. "=" .. override[name]
    end
  end
  return result
end

--- Result returned from load_dotenv()/load_embedded_dotenv().
local record LoadResult
  count: integer
  source: string
  --- Per-entry failures (an unreadable directory or file, env.set
  --- errors). Loading continues past them; an empty list means a
  --- clean load.
  errors: {string}
end

local record EnvModule
  get: function(name: string): string | nil
  get_or: function(name: string, default: string): string
  set: function(name: string, value: string, overwrite?: boolean): boolean, string
  unset: function(name: string): boolean, string
  all: function(): {string: string}
  type ListOptions = ListOptions
  list: function(opts?: ListOptions): {string}

  type LoadResult = LoadResult
  expand: function(value: string, ctx: {string: string}): string
  parse_dotenv: function(content: string, ctx?: {string: string}): {string: string}
  format_dotenv: function(vars: {string: string}): string
  load_dotenv: function(dir: string): LoadResult
  load_embedded_dotenv: function(): LoadResult
end

-- Declared before the dotenv section so the loader can reach set/get
-- through the module table, where tests intercept them
-- (env_dotenv_test monkey-patches env.set to simulate a failure).
local M: EnvModule

local EMBEDDED_DOTENV_PATH < const > = "/zip/embed/env.d"

--- Expand ${VAR}, ${VAR:-default}, and ${VAR-default} references in a
--- string. Looks up variables in ctx first, then falls back to the
--- process environment. Undefined variables with no default expand to
--- empty string; a malformed ${...} expression is left as-is.
--- @param value string The string to expand
--- @param ctx {string: string} Context of previously defined variables
--- @return string The expanded string
local function expand(value: string, ctx: {string: string}): string
  return (value:gsub("%${([^}]+)}", function(expr: string): string
        -- ${VAR:-default} — use default if unset or empty
        local name, default = expr:match("^([A-Za-z_][A-Za-z0-9_]*):%-(.*)")
        if name then
          local v = ctx[name] or M.get(name)
          if v and v ~= "" then
            return v
          end
          return default
        end
        -- ${VAR-default} — use default if unset (empty is ok)
        name, default = expr:match("^([A-Za-z_][A-Za-z0-9_]*)%-(.*)")
        if name then
          local v = ctx[name] or M.get(name)
          if v ~= nil then
            return v
          end
          return default
        end
        -- ${VAR} — plain expansion
        name = expr:match("^([A-Za-z_][A-Za-z0-9_]*)$")
        if name then
          return ctx[name] or M.get(name) or ""
        end
        -- malformed expression — leave as-is
        return "${" .. expr .. "}"
      end))
end

--- Parse a dotenv-format string. Returns a map of KEY=VALUE pairs.
--- Lines starting with # are comments; blank lines are skipped; a
--- line whose key does not match the key grammar is ignored. Values
--- undergo ${VAR} expansion using ctx as the lookup context.
--- @param content string The dotenv content to parse
--- @param ctx? {string: string} Context for variable expansion (default: {})
--- @return {string: string} Parsed key-value pairs
local function parse_dotenv(content: string, ctx?: {string: string}): {string: string}
  local vars: {string: string} = {}
  local lookup: {string: string} = {}
  if ctx then
    for k, v in pairs(ctx) do
      lookup[k] = v
    end
  end
  for line in content:gmatch("[^\r\n]+") do
    -- skip comments and blank lines
    if not line:match("^%s*#") and not line:match("^%s*$") then
      local key, value = line:match("^([A-Za-z_][A-Za-z0-9_]*)=(.*)")
      if key then
        local expanded = expand(value, lookup)
        vars[key] = expanded
        lookup[key] = expanded
      end
    end
  end
  return vars
end

--- Format a map of variables as dotenv text: one KEY=VALUE line per
--- entry, sorted by key, each newline-terminated (an empty map
--- formats to ""). The format half of parse_dotenv (rule 6). The
--- result round-trips through parse_dotenv when keys match the dotenv
--- key grammar and values contain no newlines or ${...} references —
--- format does not escape, because the format has no escape syntax.
--- @param vars {string:string} The variables to format
--- @return string The dotenv text
local function format_dotenv(vars: {string: string}): string
  local keys: {string} = {}
  for k in pairs(vars) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local lines: {string} = {}
  for _, k in ipairs(keys) do
    lines[#lines + 1] = k .. "=" .. vars[k] .. "\n"
  end
  return table.concat(lines)
end

--- Load env vars from a directory of dotenv files. Files are read in
--- lexical order and concatenated — later files can override keys from
--- earlier files. Existing env vars are never overwritten. A missing
--- or unreadable directory is reported in the result's errors (see
--- load_embedded_dotenv for the call where an absent directory is an
--- ordinary state rather than a defect).
---
--- When COSMIC_DEBUG is set, prints the name (not value) of each
--- variable set or skipped to stderr, along with the source file.
---
--- @param dir string The directory to read dotenv files from
--- @return LoadResult Count of variables set, source path, and errors
local function load_dotenv(dir: string): LoadResult
  local result: LoadResult = {count = 0, source = dir, errors = {}}
  local cosmic_debug_val = M.get("COSMIC_DEBUG")
  local debug_on = cosmic_debug_val ~= nil and cosmic_debug_val ~= ""

  local dh, dh_err = unix.opendir(dir)
  if not dh then
    -- The fix that rode the #994 fold: an unreadable directory used to
    -- return empty success, visible only under COSMIC_DEBUG.
    table.insert(result.errors, "open " .. dir .. ": " .. (dh_err or "unreadable"))
    if debug_on then
      io.stderr:write("[env] skip " .. dir .. ": " .. (dh_err or "not found") .. "\n")
    end
    return result
  end

  local names: {string} = {}
  while true do
    local name = dh:read()
    if not name then break end
    if name ~= "." and name ~= ".." then
      names[#names + 1] = name
    end
  end
  dh:close()
  table.sort(names)

  -- concatenate all files in lexical order, track which file each key came from
  local merged: {string: string} = {}
  local sources: {string: string} = {}
  for _, name in ipairs(names) do
    local path = dir .. "/" .. name
    -- The binding error already names the path (e.g. "open: /x: ENOENT").
    local content, read_err = cosmo.Slurp(path)
    if content then
      local vars = parse_dotenv(content, merged)
      for key, value in pairs(vars) do
        merged[key] = value
        sources[key] = name
      end
    else
      table.insert(result.errors, read_err or ("read " .. path .. ": unreadable"))
      if debug_on then
        io.stderr:write("[env] skip " .. name .. ": " .. (read_err or "unreadable") .. "\n")
      end
    end
  end

  -- apply in sorted key order for deterministic behavior
  local keys: {string} = {}
  for key in pairs(merged) do
    keys[#keys + 1] = key
  end
  table.sort(keys)

  for _, key in ipairs(keys) do
    local existing = M.get(key)
    if existing then
      if debug_on then
        io.stderr:write("[env] skip " .. key .. " from " .. sources[key] .. ": overridden by environment\n")
      end
    else
      local set_ok, set_err = M.set(key, merged[key], false)
      if not set_ok then
        table.insert(result.errors, "set " .. key .. ": " .. (set_err or "failed"))
      else
        result.count = result.count + 1
        if debug_on then
          io.stderr:write("[env] set " .. key .. " from " .. sources[key] .. "\n")
        end
      end
    end
  end

  if debug_on then
    io.stderr:write("[env] loaded " .. tostring(result.count) .. " variable(s) from " .. dir .. "\n")
  end

  return result
end

--- Load env vars from the embedded /zip/embed/env.d directory.
--- Call this early in startup, before code that depends on the
--- variables. A binary with no embedded env.d is an ordinary state,
--- not a defect: an absent directory returns a clean empty result,
--- while an unreadable one is an error like any other.
--- @return LoadResult Count of variables set, source path, and errors
local function load_embedded_dotenv(): LoadResult
  if not cpath.isdir(EMBEDDED_DOTENV_PATH) then
    return {count = 0, source = EMBEDDED_DOTENV_PATH, errors = {}}
  end
  return load_dotenv(EMBEDDED_DOTENV_PATH)
end

M = {
  get = get,
  get_or = get_or,
  set = set,
  unset = unset,
  all = all,
  list = list,

  expand = expand,
  parse_dotenv = parse_dotenv,
  format_dotenv = format_dotenv,
  load_dotenv = load_dotenv,
  load_embedded_dotenv = load_embedded_dotenv,
}

return M
