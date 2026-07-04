--- Environment variable utilities.
--- Provides get, set, unset, clear, and all functions for environment variables.
--- For the common case of reading a single variable, use env.get() — it wraps
--- os.getenv() internally and is the simplest approach. Use env.all() to get
--- all variables as a {string:string} map parsed from unix.environ().
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str

--- Get the value of an environment variable.
--- Returns nil if the variable is not set.
--- @param name string The name of the environment variable
--- @return string? The value of the environment variable, or nil if not set
local function get(name: string): string
  return os.getenv(name)
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

--- Clear all environment variables.
--- Warning: This removes ALL environment variables from the process.
--- @return boolean True on success
--- @return string? Error message if clearing failed
local function clear(): boolean, string
  -- clearenv is declared `function()` upstream (missing its boolean/Errno
  -- return), so the cast stays until that annotation is fixed.
  local ok, err = unix.clearenv() as(boolean, any)
  if not ok then
    return false, errstr(err, "clearenv")
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

--- Get all environment variables as a list.
--- Returns a list of "KEY=VALUE" strings suitable for passing to
--- child.spawn or execve.
--- @return {string} A list of "KEY=VALUE" strings
local function list(): {string}
  local entries = unix.environ()
  local result: {string} = {}
  for _, entry in ipairs(entries) do
    table.insert(result, entry)
  end
  return result
end

local record EnvModule
  get: function(name: string): string
  set: function(name: string, value: string, overwrite?: boolean): boolean, string
  unset: function(name: string): boolean, string
  clear: function(): boolean, string
  all: function(): {string: string}
  list: function(): {string}
end

local M: EnvModule = {
  get = get,
  set = set,
  unset = unset,
  clear = clear,
  all = all,
  list = list,
}

return M
