--- Restrict filesystem visibility to an allowlisted set of paths.
---
--- Once a process calls unveil with any path, the entire filesystem is
--- hidden except for the paths that have been unveiled. Paths are then
--- revealed one at a time with their allowed permission set. When done,
--- call `apply(nil, nil)` to commit the policy; further unveil calls
--- become no-ops or errors.
---
--- Unveil pairs naturally with `cosmic.pledge`: pledge narrows which
--- system calls are allowed; unveil narrows which files those calls can
--- touch.
---
--- Permissions (strings, combinable):
---
---   r  read-only path operations (matches pledge "rpath")
---   w  write operations           (matches pledge "wpath")
---   x  execute operations         (matches pledge "exec" / "execnative")
---   c  create and remove paths    (matches pledge "cpath")
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str

--- Unveil a path, or commit the policy.
---
--- Call with a path and permission string to expose the path. Call with
--- (nil, nil) to commit the policy and prevent further unveil calls.
---
--- @param path string|nil Path to unveil (nil to commit)
--- @param permissions string|nil Permission string like "r", "rw", "rwxc" (nil to commit)
--- @return boolean True on success
--- @return string? Error message on failure
local function apply(path: string, permissions: string): boolean, string
  local ok, err = unix.unveil(path, permissions)
  if not ok then
    return false, errstr(err, "unveil")
  end
  return true
end

local record UnveilModule
  apply: function(path: string, permissions: string): boolean, string
end

local M: UnveilModule = {
  apply = apply,
}

return M
