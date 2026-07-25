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
--- and non-Linux hosts; gate box setup on it. Pairs naturally with
--- `cosmic.pledge` on Linux and is complementary to `cosmic.quicksand`
--- network isolation.
local unix = require("cosmo.unix")

local EXECUTE < const > = unix.LANDLOCK_ACCESS_FS_EXECUTE
local WRITE_FILE < const > = unix.LANDLOCK_ACCESS_FS_WRITE_FILE
local READ_FILE < const > = unix.LANDLOCK_ACCESS_FS_READ_FILE
local READ_DIR < const > = unix.LANDLOCK_ACCESS_FS_READ_DIR
local REMOVE_DIR < const > = unix.LANDLOCK_ACCESS_FS_REMOVE_DIR
local REMOVE_FILE < const > = unix.LANDLOCK_ACCESS_FS_REMOVE_FILE
local MAKE_CHAR < const > = unix.LANDLOCK_ACCESS_FS_MAKE_CHAR
local MAKE_DIR < const > = unix.LANDLOCK_ACCESS_FS_MAKE_DIR
local MAKE_REG < const > = unix.LANDLOCK_ACCESS_FS_MAKE_REG
local MAKE_SOCK < const > = unix.LANDLOCK_ACCESS_FS_MAKE_SOCK
local MAKE_FIFO < const > = unix.LANDLOCK_ACCESS_FS_MAKE_FIFO
local MAKE_BLOCK < const > = unix.LANDLOCK_ACCESS_FS_MAKE_BLOCK
local MAKE_SYM < const > = unix.LANDLOCK_ACCESS_FS_MAKE_SYM
local REFER < const > = unix.LANDLOCK_ACCESS_FS_REFER -- ABI 2+
local TRUNCATE < const > = unix.LANDLOCK_ACCESS_FS_TRUNCATE -- ABI 3+

--- Convenience masks. `ALL` is the full current set; `RW` covers read
--- + write (including creating and removing files) but *not* execute —
--- OR in `EXEC` explicitly if files under the path must be runnable.
--- `READ` and `EXEC` are self-explanatory.
local READ < const > = READ_FILE | READ_DIR
local EXEC < const > = EXECUTE
--- Access bits that can attach to a non-directory inode. The kernel
--- rejects a rule carrying directory-only rights (READ_DIR, MAKE_*,
--- REMOVE_*, REFER) on a regular file with EINVAL, so restrict() masks
--- file rules down to these — mirroring what the libc unveil path does
--- after fstat.
local FILE_BITS < const > = READ_FILE | WRITE_FILE | EXECUTE | TRUNCATE
local WRITE < const > = WRITE_FILE | REMOVE_FILE | REMOVE_DIR
| MAKE_REG | MAKE_DIR | MAKE_SYM
| MAKE_SOCK | MAKE_FIFO | MAKE_CHAR | MAKE_BLOCK
local RW < const > = READ | WRITE
local ALL < const > = READ | WRITE | EXEC | REFER | TRUNCATE

--- A single path -> access-mask rule in a restrict() call.
--- `access` is an OR of cosmic.landlock.* flag constants (READ, EXEC,
--- WRITE_FILE, MAKE_REG, etc.) and must be a subset of the call's
--- `handled` mask. When `path` is not a directory, directory-only
--- rights are stripped automatically, so `access = READ` works on a
--- regular file even though READ bundles READ_DIR.
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
local record RestrictOptions
  handled: integer
  rules: {Rule}
  no_new_privs: boolean
end

local record LandlockModule
  type Rule = Rule
  type RestrictOptions = RestrictOptions
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
  abi: function(): integer | nil, string
  available: function(): boolean
  restrict: function(opts: RestrictOptions): boolean, string
end

--- Per-ABI "max access" mask. Categories above the kernel's supported
--- ABI MUST be stripped before create_ruleset or it returns EINVAL.
local function abi_mask(abi_version: integer): integer
  local mask = READ | WRITE_FILE | REMOVE_DIR | REMOVE_FILE
  | MAKE_CHAR | MAKE_DIR | MAKE_REG | MAKE_SOCK
  | MAKE_FIFO | MAKE_BLOCK | MAKE_SYM | EXECUTE
  if abi_version >= 2 then mask = mask | REFER end
  if abi_version >= 3 then mask = mask | TRUNCATE end
  return mask
end

--- Returns the kernel's supported landlock ABI version (>= 1 when
--- landlock is enabled). Returns nil + error on ENOSYS or non-Linux.
local function abi(): integer | nil, string
  local v, err = unix.landlock_create_ruleset()
  if not v then
    return nil, err and tostring(err) or "landlock unavailable"
  end
  return v
end

--- True when abi() >= 1. Gate box setup on this.
local function available(): boolean
  local a = abi()
  return a ~= nil and a >= 1
end

--- Apply a path allowlist to the current thread and all its future
--- children. Irreversible.
---
--- Access outside the allowlist fails with EACCES after this returns.
--- Access categories above the running kernel's ABI are stripped from
--- `handled` automatically, so `cosmic.landlock.ALL` stays portable.
--- The ruleset fd is always closed before return.
---
--- Known gap: TRUNCATE is only handleable on landlock ABI >= 3, so on
--- older kernels a restricted process can still truncate(2) files
--- outside its allowlist. (Cosmopolitan's C unveil path plugs this with
--- a seccomp filter; this module does not.) Pair with `cosmic.pledge`
--- — truncate is governed by its "wpath" group — where that matters.
local function restrict(opts: RestrictOptions): boolean, string
  opts = opts or {}
  local abi_version, aerr = abi()
  if not abi_version then return false, aerr end
  if abi_version < 1 then return false, "landlock unavailable" end
  local mask = abi_mask(abi_version)
  local handled = (opts.handled or ALL) & mask
  local rs, cerr = unix.landlock_create_ruleset(handled, 0)
  if not rs then return false, tostring(cerr) end
  local rsfd = rs
  local function fail(msg: string): boolean, string
    unix.close(rsfd)
    return false, msg
  end
  for i, rule in ipairs(opts.rules or {}) do
    if not rule.path then
      return fail(string.format("rule[%d] missing path", i))
    end
    local access = (rule.access or 0) & mask
    local pfd, perr = unix.open(rule.path,
      (unix.O_PATH) | (unix.O_CLOEXEC))
    if not pfd then
      return fail(string.format("open(%q): %s", rule.path, tostring(perr)))
    end
    -- Directory-only rights on a non-directory rule are an EINVAL from
    -- the kernel; strip them so file paths accept the composite masks
    -- (READ, RW, ...). A rule left with no grantable bits is skipped —
    -- landlock denies by default, so granting nothing needs no rule.
    local st = unix.fstat(pfd)
    -- cast: record union after guard
    if st and not unix.S_ISDIR((st as unix.Stat):mode()) then
      access = access & FILE_BITS
    end
    if access ~= 0 then
      local ok, rerr = unix.landlock_add_rule(rsfd, pfd, access, 0)
      if not ok then
        unix.close(pfd)
        return fail(string.format("add_rule(%q): %s", rule.path, tostring(rerr)))
      end
    end
    unix.close(pfd)
  end
  if opts.no_new_privs ~= false then
    local ok, err = unix.prctl(unix.PR_SET_NO_NEW_PRIVS, 1)
    if not ok then return fail("PR_SET_NO_NEW_PRIVS: " .. tostring(err)) end
  end
  -- flush line-coverage data before rights drop: once the ruleset
  -- lands, the coverage directory may no longer be writable
  local cov = package.loaded["cosmic.coverage"]
  if cov ~= nil then
    -- cast: from any; function shape
    local seal = (cov as {string: any})["seal"] as function()
    seal()
  end
  local ok, rerr = unix.landlock_restrict_self(rsfd, 0)
  unix.close(rsfd)
  if not ok then return false, "restrict_self: " .. tostring(rerr) end
  return true
end

local M: LandlockModule = {
  EXECUTE = EXECUTE,
  WRITE_FILE = WRITE_FILE,
  READ_FILE = READ_FILE,
  READ_DIR = READ_DIR,
  REMOVE_DIR = REMOVE_DIR,
  REMOVE_FILE = REMOVE_FILE,
  MAKE_CHAR = MAKE_CHAR,
  MAKE_DIR = MAKE_DIR,
  MAKE_REG = MAKE_REG,
  MAKE_SOCK = MAKE_SOCK,
  MAKE_FIFO = MAKE_FIFO,
  MAKE_BLOCK = MAKE_BLOCK,
  MAKE_SYM = MAKE_SYM,
  REFER = REFER,
  TRUNCATE = TRUNCATE,
  READ = READ,
  EXEC = EXEC,
  WRITE = WRITE,
  RW = RW,
  ALL = ALL,
  abi = abi,
  available = available,
  restrict = restrict,
}

return M
