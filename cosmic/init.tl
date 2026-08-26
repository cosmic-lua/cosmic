--- cosmic: a batteries-included Lua/Teal distribution built on
--- Cosmopolitan Libc. Main entry point helper for cosmic programs.

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
---
--- The function receives the command-line arguments and an environment
--- with stdout/stderr, and returns an exit code plus an optional error
--- message, which is written to stderr.
---
--- It does NOT check `is_main` itself, and cannot: `cosmo.is_main()`
--- answers for the chunk that CALLS it, and this chunk is always
--- `cosmic/init.tl`, never your script. A guard here is therefore
--- false every time, and every caller silently does nothing — a
--- failure a test that asserts the function exists cannot see. A file
--- that is both a module and a script asks in its OWN chunk, where the
--- answer is about that file:
---
---     if proc.is_main() then
---       cosmic.main(function(args: {string}): number, string … end)
---     end
--- @param fn function The main function to execute
local function main(fn: function(args: {string}, env: Env): number, string)
  local env: Env = {stderr = io.stderr, stdout = io.stdout}
  local code, err = fn(arg, env)
  if err then env.stderr:write(err .. "\n") end
  -- Any numeric return exits honestly: a fractional code (a stray
  -- average, a division) exits 1 instead of throwing at the very end,
  -- and an error return with no code exits 1, never a clean 0.
  -- exits: entry helper; the caller is the OS
  os.exit(math.tointeger(code or (err and 1 or 0)) or 1)
end

--- The build-injected version stamps, or nil outside a packed binary.
---
--- `cosmic._version` is generated at build time and embedded in the
--- artifact, so it does not exist in the tree and the checker cannot
--- resolve it: the module name is a local rather than a literal
--- argument, and this function is the one place in the repo that pays
--- for that dynamism. `is` narrows the pcall result to the declared
--- record with a table test, so every caller reads typed fields
--- instead of casting a value out of `any`.
--- @return VersionInfo|nil The embedded stamps, or nil when there are none
local function version_info(): VersionInfo | nil
  local mod = "cosmic._version"
  local ok, info = pcall(require, mod)
  if ok and info is VersionInfo then
    return info
  end
  return nil
end

--- The build-injected version string, or "unknown" outside a packed
--- binary (cosmic._version is generated at build time and embedded).
local function version(): string
  local info = version_info()
  if info and info.cosmic then
    return info.cosmic
  end
  return "unknown"
end

local record cosmic
  --- The environment main() hands your function, exported so callers
  --- can annotate the parameter (`env: cosmic.Env`).
  type Env = Env

  --- The build stamps version_info() returns, exported so callers can
  --- annotate what they hold (`v: cosmic.VersionInfo`).
  type VersionInfo = VersionInfo

  _VERSION: string
  _DESCRIPTION: string
  main: function(fn: function(args: {string}, env: Env): number, string)
  version_info: function(): VersionInfo | nil
end

local M: cosmic = {
  _VERSION = version(),
  _DESCRIPTION = "cosmic: a batteries-included Lua/Teal distribution "
  .. "built on Cosmopolitan Libc",
  main = main,
  version_info = version_info,
}

return M
