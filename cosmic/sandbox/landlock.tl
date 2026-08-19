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
---     local ll = require("cosmic.sandbox.landlock")
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
local errno = require("cosmic.errno")
local unix = require("cosmo.unix")
local seal_coverage = require("cosmic._seal_coverage").seal_coverage

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
--- TRUNCATE is part of WRITE, not an extra. It is a SEPARATE right
--- from ABI 3 on, and `ALL` -- the handled set -- includes it, so
--- leaving it out of the grant made "read-write" mean "create, but
--- never rewrite": `open(O_TRUNC)` on a file that already exists was
--- denied inside a directory the policy had just granted rw. It hid
--- behind write-if-changed, which usually creates rather than rewrites,
--- and surfaced as the one recipe that always rewrites (`copy`) failing
--- with EACCES on its second build. `abi_mask` strips it below ABI 3.
--- REFER is part of WRITE for the same reason: with it handled but not
--- granted, "read-write" meant "create, but never move" -- rename(2)
--- and link(2) between two directories of the same rw tree failed with
--- EXDEV -- and the workload that surfaced it is git, whose object
--- store finalizes every push by cross-directory rename. Moving an
--- entry between two DIFFERENTLY-granted trees still requires REFER
--- plus the matching make/remove rights on both sides, so the grant
--- widens nothing across trees. `abi_mask` strips it below ABI 2 (on
--- ABI 1 kernels landlock denies cross-directory moves outright and no
--- grant can allow them).
local WRITE < const > = WRITE_FILE | TRUNCATE | REMOVE_FILE | REMOVE_DIR
| MAKE_REG | MAKE_DIR | MAKE_SYM
| MAKE_SOCK | MAKE_FIFO | MAKE_CHAR | MAKE_BLOCK
| REFER
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
  --- Skip this rule when its path is absent at open time: the rule
  --- would grant nothing, and an optional policy prefers a narrower
  --- sandbox over none. Absence is judged by the open itself (ENOENT),
  --- never by a pre-check — a pre-check is a race, and a dangling
  --- symlink passes it only to fail here anyway.
  optional: boolean
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
  --- Turn an unsupported host into a successful no-op instead of an
  --- error — the explicit fail-open escape hatch, matching
  --- cosmic.pledge and cosmic.unveil.
  best_effort: boolean
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
  restrict: function(opts?: RestrictOptions): boolean, string
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

-- The kernel's ABI answer cannot change within a process; probe once
-- and cache, matching pledge.available() / unveil.available().
local abi_cached: integer = nil
local abi_cached_err: string = nil
local abi_probed: boolean = false

--- Returns the kernel's supported landlock ABI version (>= 1 when
--- landlock is enabled). Returns nil + error on ENOSYS or non-Linux.
--- Probed once and cached.
local function abi(): integer | nil, string
  if not abi_probed then
    abi_probed = true
    local v, err = unix.landlock_create_ruleset()
    if v then
      abi_cached = v
    else
      abi_cached_err = err and ("landlock: " .. tostring(err))
      or "landlock: unsupported on this host"
    end
  end
  if abi_cached == nil then
    return nil, abi_cached_err
  end
  return abi_cached
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
local function restrict(opts?: RestrictOptions): boolean, string
  opts = opts or {}
  if not available() then
    if opts.best_effort then return true end
    return false, "landlock: unsupported on this host"
  end
  local abi_version = abi()
  if abi_version == nil then
    -- Unreachable past the available() gate; kept so the narrowing is
    -- honest rather than cast.
    return false, "landlock: unsupported on this host"
  end
  local mask = abi_mask(abi_version)
  local handled = (opts.handled or ALL) & mask
  local rs, cerr = unix.landlock_create_ruleset(handled, 0)
  if not rs then
    return false, "landlock: create_ruleset: " .. tostring(cerr)
  end
  local rsfd = rs
  local function fail(msg: string): boolean, string
    unix.close(rsfd)
    return false, msg
  end
  for i, rule in ipairs(opts.rules or {}) do
    if not rule.path then
      return fail(string.format("landlock: rule[%d] missing path", i))
    end
    -- A rule's access must be a subset of `handled`, or
    -- landlock_add_rule(2) returns EINVAL — intersect against the
    -- actual handled set (not just the ABI mask) so a caller that
    -- narrows `handled` gets exactly that access, never a kernel error.
    local access = (rule.access or 0) & handled
    local pfd, perr, peno = unix.open(rule.path,
      (unix.O_PATH) | (unix.O_CLOEXEC))
    if not pfd and rule.optional and errno.is_code(peno, "ENOENT") then
      -- Absent under optional: grant nothing for this path, keep going.
    elseif not pfd then
      return fail(string.format("landlock: open(%q): %s",
          rule.path, tostring(perr)))
    else
      -- Directory-only rights on a non-directory rule are an EINVAL from
      -- the kernel; strip them so file paths accept the composite masks
      -- (READ, RW, ...). A rule left with no grantable bits is skipped —
      -- landlock denies by default, so granting nothing needs no rule.
      local st = unix.fstat(pfd)
      if st and not unix.S_ISDIR(st:mode()) then
        access = access & FILE_BITS
      end
      if access ~= 0 then
        local ok, rerr = unix.landlock_add_rule(rsfd, pfd, access, 0)
        if not ok then
          unix.close(pfd)
          return fail(string.format("landlock: add_rule(%q): %s",
              rule.path, tostring(rerr)))
        end
      end
      unix.close(pfd)
    end
  end
  if opts.no_new_privs ~= false then
    local ok, err = unix.prctl(unix.PR_SET_NO_NEW_PRIVS, 1)
    if not ok then
      return fail("landlock: PR_SET_NO_NEW_PRIVS: " .. tostring(err))
    end
  end
  -- Flush line-coverage data before rights drop: once the ruleset
  -- lands, the coverage directory MAY no longer be writable, and
  -- sealing is the only safe answer to "may". A caller that has
  -- removed the doubt (the recipe fence grants its own coverage
  -- directory — see `_cli/grants.tl`) marks cosmic.coverage instead;
  -- the seal-vs-keep rule lives in cosmic._seal_coverage, shared with
  -- pledge/unveil.
  seal_coverage()
  local ok, rerr = unix.landlock_restrict_self(rsfd, 0)
  unix.close(rsfd)
  if not ok then
    return false, "landlock: restrict_self: " .. tostring(rerr)
  end
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
