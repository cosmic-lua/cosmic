--- Environment variable utilities.
--- Provides get, set, unset, clear, and all functions for environment variables.
--- For the common case of reading a single variable, use env.get(), which
--- returns nil when the variable is not set, or env.get_or() when you have
--- a fallback. Use env.all() to get all variables as a {string:string} map
--- parsed from unix.environ().
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

--- Clear all environment variables.
--- Warning: This removes ALL environment variables from the process.
--- @return boolean True on success
--- @return string? Error message if clearing failed
local function clear(): boolean, string
  local ok, err = unix.clearenv()
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

local record EnvModule
  get: function(name: string): string | nil
  get_or: function(name: string, default: string): string
  set: function(name: string, value: string, overwrite?: boolean): boolean, string
  unset: function(name: string): boolean, string
  clear: function(): boolean, string
  all: function(): {string: string}
  type ListOptions = ListOptions
  list: function(opts?: ListOptions): {string}
end

local M: EnvModule = {
  get = get,
  get_or = get_or,
  set = set,
  unset = unset,
  clear = clear,
  all = all,
  list = list,
}

return M
