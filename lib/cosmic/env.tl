--- Environment variable utilities.
--- Wraps cosmo.unix environment functions: get, set, unset, clear, all.
local unix = require("cosmo.unix")

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
  local ok, err = unix.setenv(name, value, overwrite) as(boolean, any)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Unset an environment variable.
--- @param name string The name of the environment variable to remove
--- @return boolean True on success
--- @return string? Error message if unsetting failed
local function unset(name: string): boolean, string
  local ok, err = unix.unsetenv(name) as(boolean, any)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Clear all environment variables.
--- Warning: This removes ALL environment variables from the process.
--- @return boolean True on success
--- @return string? Error message if clearing failed
local function clear(): boolean, string
  local ok, err = unix.clearenv() as(boolean, any)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Get all environment variables.
--- Returns a table mapping variable names to their values.
--- @return {string:string} A table of all environment variables
local function all(): {string: string}
  return unix.environ() as {string: string}
end

local record EnvModule
  get: function(name: string): string
  set: function(name: string, value: string, overwrite?: boolean): boolean, string
  unset: function(name: string): boolean, string
  clear: function(): boolean, string
  all: function(): {string: string}
end

local M: EnvModule = {
  get = get,
  set = set,
  unset = unset,
  clear = clear,
  all = all,
}

return M
