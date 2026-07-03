--- cosmo.sandbox.fs: filesystem-isolation helpers.
---
--- Composable pieces built on the `unix.*` mount + pivot_root +
--- chroot primitives. The two main consumers are the netns-proxy and
--- claude-code examples, but any caller building a private mount
--- namespace can use them.
---
--- All helpers return `nil, unix.Errno` on failure, matching the
--- rest of cosmo's lunix API. Callers add their own context string
--- at the call site (they know what operation they were doing);
--- programmatic errno checks use `err:errno() == unix.EACCES` and
--- human-readable strings come from `tostring(err)`.
---
--- Linux-only.

local unix = require "unix"

local M = {}

--- Octal mode constants. Lua has no octal literal, so define them once
--- explicitly (instead of accidentally writing `0x755` and getting
--- decimal 1877 / octal 03525).
M.MODE_DIR        = tonumber("755",  8)  -- 0o755 = 493 = rwxr-xr-x
M.MODE_DIR_PRIV   = tonumber("700",  8)  -- 0o700 = 448 = rwx------
M.MODE_FILE       = tonumber("644",  8)  -- 0o644 = 420 = rw-r--r--
M.MODE_TMP_STICKY = tonumber("1777", 8)  -- 0o1777      = sticky+rwxrwxrwx

--- True if `path` exists (any type).
function M.exists(path)
  return unix.stat(path) ~= nil
end

-- Return the parent dir of `path` (or "/" for top-level).
local function parent_dir(path)
  return string.match(path, "(.+)/[^/]+$") or "/"
end

-- Create a mount-point at `dst` matching the type of `src` — a
-- directory if src is a directory, else an empty file. Used internally
-- by bind() to ensure dst exists with the right kind before mounting.
local function ensure_mountpoint(src, dst)
  local st, err = unix.stat(src)
  if not st then return nil, err end
  if (st:mode() & 0xf000) == 0x4000 then
    -- Directory: makedirs is idempotent.
    local ok, err = unix.makedirs(dst, M.MODE_DIR)
    if not ok then return nil, err end
  else
    -- File-like: ensure parent dir, then touch the dst as an empty file.
    local ok, err = unix.makedirs(parent_dir(dst), M.MODE_DIR)
    if not ok then return nil, err end
    if not M.exists(dst) then
      local fd, ferr = unix.open(dst, unix.O_WRONLY | unix.O_CREAT,
                                 M.MODE_FILE)
      if not fd then return nil, ferr end
      unix.close(fd)
    end
  end
  return true
end

-- Parse /proc/self/mountinfo and return an array of mount-point paths
-- that are strictly under `prefix` (i.e. prefix is a proper ancestor).
-- mountinfo format (kernel Documentation/filesystems/proc.rst, field 5):
--   <mountid> <parentid> <major>:<minor> <root> <mountpoint> <mountopts>
--   [optional fields] - <fstype> <source> <superopts>
-- Field 5 (1-indexed) is the mount point; spaces inside paths are encoded
-- as the octal escape \040. We use io.open so this has no dependency on
-- any unix.* extension beyond what the rest of this module already needs.
local function submounts_under(prefix)
  -- Normalise prefix: strip trailing slash unless it is the root itself.
  local norm = prefix:gsub("/+$", "")
  if norm == "" then norm = "/" end
  local result = {}
  local f = io.open("/proc/self/mountinfo", "r")
  if not f then return result end
  for line in f:lines() do
    -- Split on spaces; field 5 is the encoded mount point.
    local fields = {}
    for tok in line:gmatch("%S+") do
      fields[#fields + 1] = tok
    end
    local mp_enc = fields[5]
    if mp_enc then
      -- Decode octal-encoded spaces (\040 → " ").
      local mp = mp_enc:gsub("\\040", " ")
      -- Include this mount if its path is strictly under norm:
      --   norm == "/" means everything qualifies
      --   otherwise the path must start with norm .. "/" (not just norm itself,
      --   which is the top-level bind we already handled).
      local is_sub
      if norm == "/" then
        is_sub = mp ~= "/"
      else
        is_sub = mp:sub(1, #norm + 1) == norm .. "/"
      end
      if is_sub then
        result[#result + 1] = mp
      end
    end
  end
  f:close()
  return result
end

--- fs.bind(src, dst[, opts]) → true | nil, err
---
--- Bind-mount `src` onto `dst` (creating dst as a file or directory as
--- needed), optionally remounting read-only. opts.ro = true requests a
--- read-only bind. opts.rec = false disables MS_REC (default true).
---
--- Read-only guarantee: MS_REC on a *remount* does NOT recursively
--- re-apply MS_RDONLY to sub-mounts that exist within the bound tree
--- (it only sets the flag on the top-level bind mount). To ensure the
--- entire subtree is truly read-only, we parse /proc/self/mountinfo
--- after the top-level RO remount and individually remount each
--- sub-mount read-only. On the common "no sub-mounts" path the extra
--- step finds nothing and adds no overhead.
---
--- The clean alternative — mount_setattr(2) with AT_RECURSIVE — would
--- accomplish this atomically in a single syscall, but unix.mount_setattr
--- is not currently exposed by lunix.c; exposing it would be a welcome
--- future improvement.
function M.bind(src, dst, opts)
  opts = opts or {}
  local rec = opts.rec ~= false
  local ok, err = ensure_mountpoint(src, dst)
  if not ok then return nil, err end
  local flags = unix.MS_BIND | (rec and unix.MS_REC or 0)
  ok, err = unix.mount(src, dst, nil, flags, nil)
  if not ok then return nil, err end
  if opts.ro then
    -- Step 1: remount the top-level bind mount read-only.
    flags = unix.MS_REMOUNT | unix.MS_BIND | unix.MS_RDONLY
    ok, err = unix.mount("none", dst, nil, flags, nil)
    if not ok then return nil, err end
    -- Step 2: walk any sub-mounts visible under dst and remount each
    -- read-only. MS_REC on a remount does not propagate MS_RDONLY into
    -- sub-mounts, so without this step a nested filesystem (e.g. if src
    -- is "/" or a directory with other filesystems mounted under it)
    -- would remain writable inside the jail.
    if rec then
      local subs = submounts_under(dst)
      for _, mp in ipairs(subs) do
        ok, err = unix.mount("none", mp, nil,
                             unix.MS_REMOUNT | unix.MS_BIND | unix.MS_RDONLY,
                             nil)
        if not ok then return nil, err end
      end
    end
  end
  return true
end

--- fs.bind_ro(src, dst) → true | nil, err
---
--- Convenience: read-only recursive bind.
function M.bind_ro(src, dst)
  return M.bind(src, dst, {ro = true})
end

--- fs.tmpfs(dst, size_or_data) → true | nil, err
---
--- Mount a tmpfs at `dst`. `size_or_data` is either a size string
--- ("128m") or a full mount-data string ("size=128m,mode=755").
--- Creates `dst` if missing.
function M.tmpfs(dst, size_or_data)
  local data
  if type(size_or_data) == "string" then
    if size_or_data:find("=") then
      data = size_or_data
    else
      data = "size=" .. size_or_data
    end
  end
  local ok, err = unix.makedirs(dst, M.MODE_DIR)
  if not ok then return nil, err end
  ok, err = unix.mount("tmpfs", dst, "tmpfs", 0, data)
  if not ok then return nil, err end
  return true
end

--- fs.private_root() → true | nil, err
---
--- Mark the existing root mount tree as MS_PRIVATE recursively, so
--- subsequent mounts in this namespace don't propagate to the host.
--- Many distros default to "shared". Call this immediately after
--- unshare(CLONE_NEWNS).
function M.private_root()
  local ok, err = unix.mount("none", "/", nil,
                             unix.MS_REC | unix.MS_PRIVATE, nil)
  if not ok then return nil, err end
  return true
end

--- fs.pivot_to(jail) → true | nil, err
---
--- Pivot the current mount namespace's root into `jail`. Detaches the
--- old root via unmount(MNT_DETACH) and removes the temporary
--- /.old mountpoint. Caller must have already populated `jail` with
--- the desired contents.
---
--- NOTE: on failure, the mount state is not unwound. A failed
--- pivot_root may leave `/.old` as an empty dir; a failed unmount
--- may leave the old root mounted at `/.old`. These only matter if
--- the caller intends to keep running in the same mount namespace.
--- The normal failure recovery is to exit the child process, which
--- the kernel cleans up when the mount namespace's last reference
--- goes away.
function M.pivot_to(jail)
  local old = jail .. "/.old"
  local ok, err = unix.makedirs(old, M.MODE_DIR_PRIV)
  if not ok then return nil, err end
  ok, err = unix.chdir(jail)
  if not ok then return nil, err end
  ok, err = unix.pivot_root(".", ".old")
  if not ok then return nil, err end
  ok, err = unix.chdir("/")
  if not ok then return nil, err end
  ok, err = unix.unmount("/.old", unix.MNT_DETACH)
  if not ok then return nil, err end
  unix.rmdir("/.old")
  return true
end

--- fs.proc(dir) → true | nil, err
---
--- Mount a private procfs at `dir` (default "/proc") using hardened
--- flags: MS_NOSUID | MS_NODEV | MS_NOEXEC.
---
--- PRECONDITION — PID namespace: this function is most useful when the
--- calling process is PID 1 of a freshly created PID namespace.  On
--- Linux, after `unshare(CLONE_NEWPID)` the CURRENT process is NOT
--- moved into the new namespace — only its future children are.  To
--- mount a procfs that shows only the sandbox's own processes you must:
---
---   1. Call `unix.unshare(unix.CLONE_NEWPID)` in the jail-setup process.
---   2. Fork a child — that child is PID 1 of the new namespace.
---   3. Call `fs.proc()` from inside that child (after pivot_root,
---      within the new mount namespace).
---
--- When called correctly the mounted procfs is fully isolated: the
--- sandboxed processes can only see each other's PIDs, preventing
--- information leakage via /proc/<pid>/environ, /proc/<pid>/cmdline,
--- /proc/<pid>/root, and /proc/sys of HOST processes.
---
--- HAZARD — binding the host /proc: if a consumer bind-mounts the host
--- /proc into the jail (e.g. `fs.bind("/proc", jail.."/proc")`), ALL
--- host-process information is visible inside the sandbox:
---   - /proc/<pid>/environ leaks environment variables of host processes
---   - /proc/<pid>/cmdline leaks command-line arguments
---   - /proc/<pid>/root is a traversable fd into each process's root
---   - /proc/sys exposes writable kernel tunables to the sandboxed process
--- Always prefer `fs.proc()` (called from within a CLONE_NEWPID child)
--- over binding the host /proc.  See proc.fork_pidns() for the helper
--- that creates the correctly-placed child.
---
--- If mounting procfs fails (e.g. the caller is not in a PID namespace
--- or there is a policy denial), the error is surfaced as nil, err so
--- the caller can decide to abort the jail setup.
function M.proc(dir)
  dir = dir or "/proc"
  local ok, err = unix.makedirs(dir, M.MODE_DIR)
  if not ok then return nil, err end
  local flags = unix.MS_NOSUID | unix.MS_NODEV | unix.MS_NOEXEC
  ok, err = unix.mount("proc", dir, "proc", flags, nil)
  if not ok then return nil, err end
  return true
end

--- fs.pivot_to_or_exit(jail[, exit_code])
---
--- Like pivot_to, but enforces the documented failure contract: on
--- error, write a diagnostic to stderr and terminate the current
--- process with unix.exit(exit_code or 127). Use from a forked child
--- that has already committed to running inside the jail and cannot
--- meaningfully recover from a half-unwound mount namespace.
---
--- Never returns on failure. Returns true on success.
function M.pivot_to_or_exit(jail, exit_code)
  local ok, err = M.pivot_to(jail)
  if not ok then
    io.stderr:write("pivot_to " .. tostring(jail) .. ": "
                    .. tostring(err) .. "\n")
    unix.exit(exit_code or 127)
  end
  return true
end

return M
