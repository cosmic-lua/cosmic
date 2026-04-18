--- Linux landlock filesystem sandbox.
---
--- Landlock is an unprivileged, process-self-restricting filesystem
--- sandbox. Any process (even running as a regular user) can narrow its
--- own file access to a declared allowlist. Once applied, the
--- restriction is inherited by children and cannot be relaxed — only
--- further narrowed.
---
--- Typical usage:
---
---     local ll = require("cosmic.landlock")
---     if not ll.available() then return end
---     local ok, err = ll.restrict{
---       rules = {
---         { path = "/usr",  access = ll.READ | ll.EXEC },
---         { path = "/tmp",  access = ll.RW },
---       },
---     }
---
--- Requires Linux >= 5.13. `available()` returns false on older kernels
--- and non-Linux hosts; gate jail setup on it. Pairs naturally with
--- `cosmic.pledge` on Linux and is complementary to `cosmic.quicksand`
--- network isolation.
local clandlock = require("cosmo.sandbox.landlock")

--- A single path -> access-mask rule in a restrict() call.
--- `access` is an OR of cosmic.landlock.* flag constants (READ, EXEC,
--- WRITE_FILE, MAKE_REG, etc.) and must be a subset of the call's
--- `handled` mask.
local record Rule
  path: string
  access: integer
end

--- Options for `restrict`. `handled` narrows which access categories
--- the sandbox controls (categories outside it are left unrestricted;
--- defaults to cosmic.landlock.ALL). `rules` lists allowed paths.
--- `no_new_privs` defaults to true (sets PR_SET_NO_NEW_PRIVS before the
--- restrict, which the kernel requires unless the caller already set it
--- or holds CAP_SYS_ADMIN).
local record RestrictOpts
  handled: integer
  rules: {Rule}
  no_new_privs: boolean
end

local record LandlockModule
  EXECUTE: integer
  WRITE_FILE: integer
  READ_FILE: integer
  READ_DIR: integer
  REMOVE_DIR: integer
  REMOVE_FILE: integer
  MAKE_CHAR: integer
  MAKE_DIR: integer
  MAKE_REG: integer
  MAKE_SOCK: integer
  MAKE_FIFO: integer
  MAKE_BLOCK: integer
  MAKE_SYM: integer
  REFER: integer
  TRUNCATE: integer
  READ: integer
  EXEC: integer
  WRITE: integer
  RW: integer
  ALL: integer
  abi: function(): integer, string
  available: function(): boolean
  restrict: function(opts: RestrictOpts): boolean, string
end

--- Returns the kernel's supported landlock ABI version (>= 1 when
--- landlock is enabled). Returns nil + error on ENOSYS or non-Linux.
local function abi(): integer, string
  local v, err = clandlock.abi()
  if not v then
    return nil, err and tostring(err) or "landlock unavailable"
  end
  return v
end

--- True when abi() >= 1. Gate jail setup on this.
local function available(): boolean
  return clandlock.available()
end

--- Apply a path allowlist to the current thread and all its future
--- children. Irreversible.
---
--- Access outside the allowlist fails with EACCES after this returns.
--- Access categories above the running kernel's ABI are stripped from
--- `handled` automatically, so `cosmic.landlock.ALL` stays portable.
local function restrict(opts: RestrictOpts): boolean, string
  return clandlock.restrict(opts as any)
end

local M: LandlockModule = {
  EXECUTE = clandlock.EXECUTE,
  WRITE_FILE = clandlock.WRITE_FILE,
  READ_FILE = clandlock.READ_FILE,
  READ_DIR = clandlock.READ_DIR,
  REMOVE_DIR = clandlock.REMOVE_DIR,
  REMOVE_FILE = clandlock.REMOVE_FILE,
  MAKE_CHAR = clandlock.MAKE_CHAR,
  MAKE_DIR = clandlock.MAKE_DIR,
  MAKE_REG = clandlock.MAKE_REG,
  MAKE_SOCK = clandlock.MAKE_SOCK,
  MAKE_FIFO = clandlock.MAKE_FIFO,
  MAKE_BLOCK = clandlock.MAKE_BLOCK,
  MAKE_SYM = clandlock.MAKE_SYM,
  REFER = clandlock.REFER,
  TRUNCATE = clandlock.TRUNCATE,
  READ = clandlock.READ,
  EXEC = clandlock.EXEC,
  WRITE = clandlock.WRITE,
  RW = clandlock.RW,
  ALL = clandlock.ALL,
  abi = abi,
  available = available,
  restrict = restrict,
}

return M
