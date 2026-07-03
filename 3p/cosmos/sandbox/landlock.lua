--- cosmo.sandbox.landlock: Linux landlock filesystem sandbox.
---
--- Landlock is an unprivileged filesystem sandbox: any process (even
--- one running as a regular user) can restrict its own file access to
--- a declared allowlist. Once applied, the restriction is inherited
--- by children and cannot be relaxed — only further narrowed.
---
--- This module wraps the raw `unix.landlock_*` syscalls with a
--- declarative path-allowlist builder. Typical flow:
---
---     local ll = require "cosmo.sandbox.landlock"
---     assert(ll.restrict{
---       handled = ll.ALL,
---       rules = {
---         {path = "/usr",  access = ll.READ | ll.EXEC},
---         {path = "/lib",  access = ll.READ | ll.EXEC},
---         {path = "/bin",  access = ll.READ | ll.EXEC},
---         {path = "/home/me/project", access = ll.RW},
---         {path = "/tmp",  access = ll.RW},
---       },
---     })
---
--- Requires Linux ≥ 5.13. `available()` returns false on older kernels
--- (or non-Linux hosts); callers should gate jail setup on it.
---
--- API-stability note: the wire protocol between the kernel and this
--- module is versioned (`abi()`), and access categories added in
--- later ABIs (REFER, TRUNCATE) are masked out automatically when the
--- kernel doesn't support them, so `ll.ALL` stays portable.

local unix = require "unix"

local M = {}

--------------------------------------------------------------------------------
-- Flag exports (so callers don't have to reach into unix.*).

M.EXECUTE     = unix.LANDLOCK_ACCESS_FS_EXECUTE
M.WRITE_FILE  = unix.LANDLOCK_ACCESS_FS_WRITE_FILE
M.READ_FILE   = unix.LANDLOCK_ACCESS_FS_READ_FILE
M.READ_DIR    = unix.LANDLOCK_ACCESS_FS_READ_DIR
M.REMOVE_DIR  = unix.LANDLOCK_ACCESS_FS_REMOVE_DIR
M.REMOVE_FILE = unix.LANDLOCK_ACCESS_FS_REMOVE_FILE
M.MAKE_CHAR   = unix.LANDLOCK_ACCESS_FS_MAKE_CHAR
M.MAKE_DIR    = unix.LANDLOCK_ACCESS_FS_MAKE_DIR
M.MAKE_REG    = unix.LANDLOCK_ACCESS_FS_MAKE_REG
M.MAKE_SOCK   = unix.LANDLOCK_ACCESS_FS_MAKE_SOCK
M.MAKE_FIFO   = unix.LANDLOCK_ACCESS_FS_MAKE_FIFO
M.MAKE_BLOCK  = unix.LANDLOCK_ACCESS_FS_MAKE_BLOCK
M.MAKE_SYM    = unix.LANDLOCK_ACCESS_FS_MAKE_SYM
M.REFER       = unix.LANDLOCK_ACCESS_FS_REFER     -- ABI 2+
M.TRUNCATE    = unix.LANDLOCK_ACCESS_FS_TRUNCATE  -- ABI 3+

--- Convenience masks. `ALL` is the full current set; `RW` covers read
--- + write (including creating and removing files); `READ` and `EXEC`
--- are self-explanatory.
M.READ = M.READ_FILE | M.READ_DIR
M.EXEC = M.EXECUTE
M.WRITE = M.WRITE_FILE | M.REMOVE_FILE | M.REMOVE_DIR
       | M.MAKE_REG | M.MAKE_DIR | M.MAKE_SYM
       | M.MAKE_SOCK | M.MAKE_FIFO | M.MAKE_CHAR | M.MAKE_BLOCK
M.RW = M.READ | M.WRITE | M.EXEC
M.ALL = M.READ | M.WRITE | M.EXEC | M.REFER | M.TRUNCATE

-- Per-ABI "max access" mask. Categories above the kernel's supported
-- ABI MUST be stripped before create_ruleset or it returns EINVAL.
local function abi_mask(abi)
  local mask = M.READ | M.WRITE_FILE | M.REMOVE_DIR | M.REMOVE_FILE
             | M.MAKE_CHAR | M.MAKE_DIR | M.MAKE_REG | M.MAKE_SOCK
             | M.MAKE_FIFO | M.MAKE_BLOCK | M.MAKE_SYM | M.EXECUTE
  if abi >= 2 then mask = mask | M.REFER end
  if abi >= 3 then mask = mask | M.TRUNCATE end
  return mask
end

--- landlock.abi() → int | nil, unix.Errno
---
--- Returns the kernel's supported landlock ABI (≥ 1 when landlock is
--- enabled). Returns nil,Errno on ENOSYS/EOPNOTSUPP — treat that as
--- "landlock not available here".
function M.abi()
  return unix.landlock_create_ruleset()
end

--- landlock.available() → bool
---
--- True when `abi() >= 1`. Use this to gate jail setup.
function M.available()
  local a = M.abi()
  return type(a) == "number" and a >= 1
end

--- landlock.restrict(opts) → true | nil, err
---
--- Apply a path-allowlist to the current thread (and future children).
--- Once applied, access outside the allowlist fails with EACCES and
--- the restriction cannot be undone.
---
--- Options:
---   handled     int mask of access categories to restrict. Categories
---               not in `handled` are left unrestricted. Defaults to
---               `landlock.ALL` (full current set, masked by ABI).
---   rules       {{path=str, access=int}, ...}  per-path allow rules.
---               `access` is an OR of landlock.READ / WRITE / EXEC /
---               or explicit landlock.ACCESS_* flags. Access must be
---               a subset of `handled`.
---   no_new_privs  bool. If true (default), call prctl(PR_SET_NO_NEW_PRIVS,
---               1) before landlock_restrict_self. Required unless the
---               caller already set it or holds CAP_SYS_ADMIN.
---
--- Returns true on success; nil,err (string) on any error. The ruleset
--- fd is always closed before return.
function M.restrict(opts)
  opts = opts or {}
  local abi, aerr = M.abi()
  if not abi then return nil, tostring(aerr) end
  if abi < 1 then return nil, "landlock unavailable" end
  local mask = abi_mask(abi)
  local handled = (opts.handled or M.ALL) & mask
  local rs, cerr = unix.landlock_create_ruleset(handled, 0)
  if not rs then return nil, tostring(cerr) end
  local function fail(msg)
    unix.close(rs)
    return nil, msg
  end
  for i, rule in ipairs(opts.rules or {}) do
    if type(rule) ~= "table" or not rule.path then
      return fail(string.format("rule[%d] missing path", i))
    end
    local access = (rule.access or 0) & mask
    local pfd, perr = unix.open(rule.path, unix.O_PATH | unix.O_CLOEXEC)
    if not pfd then
      return fail(string.format("open(%q): %s", rule.path, tostring(perr)))
    end
    local ok, rerr = unix.landlock_add_rule(rs, pfd, access, 0)
    unix.close(pfd)
    if not ok then
      return fail(string.format("add_rule(%q): %s",
                                rule.path, tostring(rerr)))
    end
  end
  if opts.no_new_privs ~= false then
    local ok, err = unix.prctl(unix.PR_SET_NO_NEW_PRIVS, 1)
    if not ok then return fail("PR_SET_NO_NEW_PRIVS: " .. tostring(err)) end
  end
  local ok, rerr = unix.landlock_restrict_self(rs, 0)
  unix.close(rs)
  if not ok then return nil, "restrict_self: " .. tostring(rerr) end
  return true
end

return M
