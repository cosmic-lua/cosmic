--- Restrict filesystem visibility to an allowlisted set of paths.
---
--- Once a process unveils any path, the entire filesystem is hidden
--- except for the paths that have been unveiled. Paths are revealed one
--- at a time with `allow(path, permissions)`; when done, `commit()`
--- seals the policy and further unveil calls become no-ops or errors.
---
--- The API is fail-closed: unveil is enforceable on OpenBSD (natively)
--- and on Linux kernels with Landlock (the libc's backing mechanism).
--- Anywhere else `allow`/`commit` return `false, "unveil unsupported on
--- this host"` instead of reporting a sandbox that does not exist.
--- Callers that prefer the old fail-open behavior opt in explicitly
--- with `best_effort = true`, or branch on `available()` themselves.
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
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str

--- Flush line-coverage data before rights drop: once visibility
--- narrows, the coverage directory may no longer be writable.
local function seal_coverage()
  local cov = package.loaded["cosmic.coverage"]
  if cov ~= nil then
    local seal = (cov as {string: any})["seal"] as function()
    seal()
  end
end

--- The permission strings `allow` accepts: every combination of r/w/x/c
--- in canonical rwxc order, as a Teal enum so typos ("rc" vs "cr",
--- "rwd") are caught at compile time. The libc itself accepts any
--- character order at runtime; untyped Lua callers are unaffected.
local enum Perm
  "r"
  "w"
  "x"
  "c"
  "rw"
  "rx"
  "rc"
  "wx"
  "wc"
  "xc"
  "rwx"
  "rwc"
  "rxc"
  "wxc"
  "rwxc"
end

--- Options for `allow` / `commit`. `best_effort` turns an unsupported
--- host into a successful no-op instead of an error — the explicit
--- fail-open escape hatch.
local record UnveilOptions
  best_effort: boolean
end

local avail: boolean = nil

--- True when unveil is actually enforceable on this host: OpenBSD, or
--- Linux with Landlock ABI >= 1. Derived, never probed with unveil
--- itself — `unix.unveil(nil, nil)` is the commit call, so probing it
--- would lock this very process into a deny-all sandbox. The libc backs
--- unveil with Landlock on Linux, so it enforces exactly when Landlock
--- does; everywhere else the raw call deliberately fails open, which is
--- precisely what this wrapper refuses to pass through. Cached.
---
--- @return boolean True when unveil can be enforced
local function available(): boolean
  if avail ~= nil then return avail end
  local host = cosmo.GetHostOs()
  if host == "OPENBSD" then
    avail = true
  elseif host == "LINUX" then
    local abi = unix.landlock_create_ruleset()
    avail = abi ~= nil and (abi) >= 1
  else
    avail = false
  end
  return avail
end

local unsupported < const > = "unveil unsupported on this host"

--- Unveil a path with the given permission set.
---
--- Fail-closed: on a host where unveil cannot be enforced this returns
--- `false, "unveil unsupported on this host"` rather than succeeding
--- without a sandbox; pass `best_effort = true` to treat that case as a
--- successful no-op.
---
--- @param path string Path to unveil
--- @param permissions string Permission string like "r", "rw", "rwxc"
--- @return boolean True on success
--- @return string? Error message on failure
local function allow(path: string, permissions: Perm, opts?: UnveilOptions): boolean, string
  if not available() then
    if opts and opts.best_effort then return true end
    return false, unsupported
  end
  seal_coverage()
  local ok, err = unix.unveil(path, permissions)
  if not ok then
    return false, errstr(err, "unveil")
  end
  return true
end

--- Commit the unveil policy: the allowlist becomes final and further
--- unveil calls are rejected. Fail-closed like `allow`.
---
--- @return boolean True on success
--- @return string? Error message on failure
local function commit(opts?: UnveilOptions): boolean, string
  if not available() then
    if opts and opts.best_effort then return true end
    return false, unsupported
  end
  seal_coverage()
  local ok, err = unix.unveil(nil, nil)
  if not ok then
    return false, errstr(err, "unveil commit")
  end
  return true
end

--- DEPRECATED compatibility shim for the pre-stable API: delegates to
--- `allow(path, permissions)`, or to `commit()` when both arguments are
--- nil (the old commit spelling). New code should call allow/commit.
---
--- @param path string|nil Path to unveil (nil to commit)
--- @param permissions string|nil Permission string (nil to commit)
--- @return boolean True on success
--- @return string? Error message on failure
local function apply(path: string, permissions: string): boolean, string
  if path == nil and permissions == nil then
    return commit()
  end
  return allow(path, permissions as Perm)
end

local record UnveilModule
  type Perm = Perm
  type UnveilOptions = UnveilOptions
  allow: function(path: string, permissions: Perm, opts?: UnveilOptions): boolean, string
  commit: function(opts?: UnveilOptions): boolean, string
  available: function(): boolean
  apply: function(path: string, permissions: string): boolean, string
end

local M: UnveilModule = {
  allow = allow,
  commit = commit,
  available = available,
  apply = apply,
}

return M
