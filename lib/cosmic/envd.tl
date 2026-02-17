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
--- Set COSMIC_DEBUG=1 to see which vars are loaded and which are skipped.
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local env = require("cosmic.env")

local ENVD_PATH = "/zip/embed/env.d"

--- Result returned from load operations.
local record LoadResult
  count: integer
  source: string
end

--- Parse a single dotenv-format string. Returns a map of KEY=VALUE pairs.
--- Lines starting with # are comments. Blank lines are skipped.
--- Keys must match [A-Za-z_][A-Za-z0-9_]*.
--- @param content string The dotenv content to parse
--- @return {string: string} Parsed key-value pairs
local function parse(content: string): {string: string}
  local vars: {string: string} = {}
  for line in content:gmatch("[^\n]+") do
    -- skip comments and blank lines
    if not line:match("^%s*#") and not line:match("^%s*$") then
      local key, value = line:match("^([A-Za-z_][A-Za-z0-9_]*)=(.*)")
      if key then
        vars[key] = value
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
  local result: LoadResult = {count = 0, source = dir}
  local debug = env.get("COSMIC_DEBUG") ~= nil

  local dh, dh_err = fs.opendir(dir)
  if not dh then
    if debug then
      io.stderr:write("[envd] skip " .. dir .. ": " .. (dh_err or "not found") .. "\n")
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
    local path = fs.join(dir, name)
    local content = cio.slurp(path)
    if content then
      local vars = parse(content)
      for key, value in pairs(vars) do
        merged[key] = value
        sources[key] = name
      end
    elseif debug then
      io.stderr:write("[envd] skip " .. name .. ": unreadable\n")
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
      env.set(key, merged[key])
      result.count = result.count + 1
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
  parse: function(content: string): {string: string}
end

local M: EnvdModule = {
  load = load,
  load_dir = load_dir,
  parse = parse,
}

return M
