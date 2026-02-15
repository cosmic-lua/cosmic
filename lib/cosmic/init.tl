--- Cosmopolitan Lua utilities.
--- Main entry point and utilities for cosmic modules.

local cosmo = require("cosmo")

--- Environment with standard output and error streams.
local record Env
  stdout: FILE
  stderr: FILE
end

--- Main function signature for cosmic programs.
--- Takes command-line arguments and environment, returns exit code and optional error message.
local type MainFn = function(args: {string}, env: Env): number, string

  --- Run a main function and exit with its return code.
  --- Calls the provided function only if running as main script.
  --- Writes error message to stderr and exits with the returned code.
  --- @param fn MainFn The main function to execute
  local function main(fn: MainFn)
    if not cosmo.is_main() then return end
    local env: Env = {stderr = io.stderr, stdout = io.stdout}
    local code, err = fn(arg, env)
    if err then env.stderr:write(err .. "\n") end
    os.exit((code or 0) as integer)
  end

  local record cosmic
    _VERSION: string
    _DESCRIPTION: string
    main: function(fn: MainFn)
  end

  local M: cosmic = {
    _VERSION = "0.1.0",
    _DESCRIPTION = "Cosmopolitan Lua utilities",
    main = main,
  }

  return M
