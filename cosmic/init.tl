--- cosmic: a batteries-included Lua/Teal distribution built on
--- Cosmopolitan Libc. Main entry point helper for cosmic programs.

local proc = require("cosmic.proc")

--- Environment with standard output and error streams.
local record Env
  stdout: FILE
  stderr: FILE
end

--- Version information embedded at build time.
local record VersionInfo
  cosmic: string
  cosmos: string
end

--- Run a main function and exit with its return code.
--- Calls the provided function only if running as main script. The
--- function receives the command-line arguments and an environment with
--- stdout/stderr, and returns an exit code plus an optional error
--- message, which is written to stderr.
--- @param fn function The main function to execute
local function main(fn: function(args: {string}, env: Env): number, string)
  if not proc.is_main() then return end
  local env: Env = {stderr = io.stderr, stdout = io.stdout}
  local code, err = fn(arg, env)
  if err then env.stderr:write(err .. "\n") end
  os.exit((code or 0) as integer) -- cast: os.exit wants integer
end

--- The build-injected version string, or "unknown" outside a packed
--- binary (cosmic._version is generated at build time and embedded).
local function version(): string
  -- Non-literal module name: cosmic._version is generated at build time,
  -- so there is no type information for it in the tree.
  local mod = "cosmic._version"
  local ok, info = pcall(require, mod)
  if ok and (info as VersionInfo).cosmic then -- cast: from any
    return (info as VersionInfo).cosmic -- cast: from any
  end
  return "unknown"
end

local record cosmic
  _VERSION: string
  _DESCRIPTION: string
  main: function(fn: function(args: {string}, env: Env): number, string)
end

local M: cosmic = {
  _VERSION = version(),
  _DESCRIPTION = "cosmic: a batteries-included Lua/Teal distribution "
  .. "built on Cosmopolitan Libc",
  main = main,
}

return M
