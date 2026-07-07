--- Load environment variables from an embedded env.d directory.
---
--- Files in the env.d directory use dotenv format: each line is either
--- a KEY=VALUE assignment or a comment (lines starting with #). Files
--- are read in lexical (sorted) order and concatenated — later assignments
--- to the same key within env.d win. Existing environment variables are
--- NOT overwritten; the real environment always takes precedence.
---
--- This follows the dotenv convention for embedding credentials (API keys,
--- tokens) into a cosmic executable:
---
---   mkdir env.d
---   echo 'ANTHROPIC_API_KEY=sk-ant-...' > env.d/api
---   cosmic --embed env.d
---
--- At startup, call envd.load() to read /zip/embed/env.d/ and set any
--- variables not already present in the environment.
---
--- Key names must match [A-Za-z_][A-Za-z0-9_]*. Blank lines and lines
--- starting with # are ignored. Values are taken as-is after the first =
--- (no trimming, no quote stripping).
---
--- Variable expansion is supported in values using ${VAR} syntax:
---   ${VAR}            expands to the value of VAR
---   ${VAR:-default}   expands to default if VAR is unset or empty
---   ${VAR-default}    expands to default if VAR is unset
--- Variables defined earlier in the same file or in earlier files (lexical
--- order) are available for expansion, as are existing environment variables.
--- Undefined variables with no default expand to empty string.
---
--- Set COSMIC_DEBUG=1 to see which vars are loaded and which are skipped.
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs_types")
local cio = require("cosmic.io")
local env = require("cosmic.env")

local ENVD_PATH = "/zip/embed/env.d"

--- Result returned from load operations.
local record LoadResult
  count: integer
  source: string
  --- Per-entry failures (unreadable files, env.set errors). Loading
  --- continues past them; an empty list means a clean load.
  errors: {string}
end

--- Expand ${VAR}, ${VAR:-default}, and ${VAR-default} references in a
--- string. Looks up variables in ctx first, then falls back to the
--- process environment. Undefined variables with no default expand to
--- empty string.
--- @param value string The string to expand
--- @param ctx {string: string} Context of previously defined variables
--- @return string The expanded string
local function expand(value: string, ctx: {string: string}): string
  return (value:gsub("%${([^}]+)}", function(expr: string): string
        -- ${VAR:-default} — use default if unset or empty
        local name, default = expr:match("^([A-Za-z_][A-Za-z0-9_]*):%-(.*)")
        if name then
          local v = ctx[name] or env.get(name)
          if v and v ~= "" then
            return v
          end
          return default
        end
        -- ${VAR-default} — use default if unset (empty is ok)
        name, default = expr:match("^([A-Za-z_][A-Za-z0-9_]*)%-(.*)")
        if name then
          local v = ctx[name] or env.get(name)
          if v ~= nil then
            return v
          end
          return default
        end
        -- ${VAR} — plain expansion
        name = expr:match("^([A-Za-z_][A-Za-z0-9_]*)$")
        if name then
          return ctx[name] or env.get(name) or ""
        end
        -- malformed expression — leave as-is
        return "${" .. expr .. "}"
      end))
end

--- Parse a single dotenv-format string. Returns a map of KEY=VALUE pairs.
--- Lines starting with # are comments. Blank lines are skipped.
--- Keys must match [A-Za-z_][A-Za-z0-9_]*.
--- Values undergo ${VAR} expansion using ctx as the lookup context.
--- @param content string The dotenv content to parse
--- @param ctx? {string: string} Context for variable expansion (default: {})
--- @return {string: string} Parsed key-value pairs
local function parse(content: string, ctx?: {string: string}): {string: string}
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

--- Load env vars from a directory of dotenv files. Files are read in
--- lexical order and concatenated — later files can override keys from
--- earlier files. Existing env vars are never overwritten.
---
--- When COSMIC_DEBUG is set, prints the name (not value) of each variable
--- set or skipped to stderr, along with the source file.
---
--- @param dir string The directory to read dotenv files from
--- @return LoadResult Result with count of variables set and source path
local function load_dir(dir: string): LoadResult
  local result: LoadResult = {count = 0, source = dir, errors = {}}
  local cosmic_debug_val = env.get("COSMIC_DEBUG")
  local debug = cosmic_debug_val ~= nil and cosmic_debug_val ~= ""

  local dh, dh_err = fs.opendir(dir)
  if not dh then
    if debug then
      io.stderr:write("[envd] skip " .. dir .. ": " .. (dh_err or "not found") .. "\n")
    end
    return result
  end

  local handle = dh as fs_types.Dir
  local names: {string} = {}
  while true do
    local name = handle:read()
    if not name then break end
    if name ~= "." and name ~= ".." then
      names[#names + 1] = name
    end
  end
  handle:close()
  table.sort(names)

  -- concatenate all files in lexical order, track which file each key came from
  local merged: {string: string} = {}
  local sources: {string: string} = {}
  for _, name in ipairs(names) do
    local path = fs.join(dir, name)
    local content, read_err = cio.slurp(path)
    if content then
      local vars = parse(content, merged)
      for key, value in pairs(vars) do
        merged[key] = value
        sources[key] = name
      end
    else
      table.insert(result.errors, "envd: " .. (read_err or (name .. ": unreadable")))
      if debug then
        io.stderr:write("[envd] skip " .. name .. ": " .. (read_err or "unreadable") .. "\n")
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
    local existing = env.get(key)
    if existing then
      if debug then
        io.stderr:write("[envd] skip " .. key .. " from " .. sources[key] .. ": overridden by environment\n")
      end
    else
      local set_ok, set_err = env.set(key, merged[key])
      if not set_ok then
        table.insert(result.errors, "envd: set " .. key .. ": " .. (set_err or "failed"))
      else
        result.count = result.count + 1
      end
      if debug then
        io.stderr:write("[envd] set " .. key .. " from " .. sources[key] .. "\n")
      end
    end
  end

  if debug then
    io.stderr:write("[envd] loaded " .. tostring(result.count) .. " variable(s) from " .. dir .. "\n")
  end

  return result
end

--- Load env vars from the embedded /zip/embed/env.d directory.
--- Call this early in startup, before code that depends on the variables.
--- @return LoadResult Result with count of variables set and source path
local function load(): LoadResult
  return load_dir(ENVD_PATH)
end

local record EnvdModule
  load: function(): LoadResult
  load_dir: function(dir: string): LoadResult
  parse: function(content: string, ctx?: {string: string}): {string: string}
  expand: function(value: string, ctx: {string: string}): string
end

local M: EnvdModule = {
  load = load,
  load_dir = load_dir,
  parse = parse,
  expand = expand,
}

return M
