--- Linux network-namespace primitives.
---
--- Typed implementation over cosmo.unix: namespace fds, setns/unshare,
--- and SIOC* interface-flag ioctls for bringing loopback up inside a
--- fresh namespace. All calls are Linux-only and return cosmic's
--- value,string error shape.
---
--- Typical flow in a forked child that wants to live in its own
--- network namespace with only loopback reachable:
---
---     local ns = require("cosmic.quicksand.netns")
---     assert(ns.unshare())
---     assert(ns.bring_up("lo"))
---
--- To enter an existing child's namespace from the parent:
---
---     local fd = assert(ns.open(child_pid))
---     assert(ns.enter(fd))
---     ns.close(fd)
local unix = require("cosmo.unix")
local errno = require("cosmic.errno")

--- Read the current IFF_* flags on `name` in the current net namespace.
--- The `struct ifreq` ABI lives in the C binding (cosmopolitan#199);
--- no kernel structs are packed here.
---
--- @param name string interface name (e.g. "lo")
--- @return integer? flags bitmask on success
--- @return string? error message on failure
local function get_flags(name: string): integer | nil, string
  if #name >= unix.IFNAMSIZ then return nil, "interface name too long" end
  local flags, err = unix.siocgifflags(name)
  if not flags then return nil, errno.wrap(err, "SIOCGIFFLAGS") end
  return flags
end

--- Set the IFF_* flags on `name` in the current net namespace.
---
--- @param name string interface name
--- @param flags integer IFF_* bitmask to write
--- @return boolean true on success
--- @return string? error message on failure
local function set_flags(name: string, flags: integer): boolean, string
  if #name >= unix.IFNAMSIZ then return false, "interface name too long" end
  local ok, err = unix.siocsifflags(name, flags)
  if not ok then return false, errno.wrap(err, "SIOCSIFFLAGS") end
  return true
end

--- Open the network namespace of `pid` as a file descriptor.
--- Pass nil (or omit) to open the current process's net namespace.
--- Caller owns the fd and must close() it when done.
---
--- O_CLOEXEC: a namespace fd that leaks across exec into a sandboxed
--- child hands it a setns(2) handle back to the parent namespace — a
--- direct sandbox escape.
---
--- @param pid integer? target pid, or nil for self
--- @return integer? fd on success
--- @return string? error message on failure
local function open(pid: integer): integer | nil, string
  local tag = pid and tostring(pid) or "self"
  local fd, err = unix.open("/proc/" .. tag .. "/ns/net",
    unix.O_RDONLY | unix.O_CLOEXEC)
  if not fd then return nil, errno.wrap(err, "netns.open") end
  return fd
end

--- Join the net namespace represented by `fd` (e.g. from open()).
--- Irreversible for the current thread; fork first if you need to
--- return to the prior namespace.
---
--- @param fd integer file descriptor for a /proc/<pid>/ns/net handle
--- @return boolean true on success
--- @return string? error message on failure
local function enter(fd: integer): boolean, string
  local ok, err = unix.setns(fd, unix.CLONE_NEWNET)
  if not ok then return false, errno.wrap(err, "setns") end
  return true
end

--- Create and enter a new user namespace in the current thread.
--- Equivalent to `unshare(CLONE_NEWUSER)`; grants the thread the
--- capabilities needed to unshare a network namespace unprivileged.
--- unshare is irreversible for the calling thread, so run it in a
--- subprocess when the original namespace must be preserved.
---
--- @return boolean true on success
--- @return string? error message on failure
local function unshare_user(): boolean, string
  local ok, err = unix.unshare(unix.CLONE_NEWUSER)
  if not ok then return false, errno.wrap(err, "unshare_user") end
  return true
end

--- Create and enter a new network namespace in the current thread.
--- Equivalent to `unshare(CLONE_NEWNET)`; requires either root or
--- unshare_user() beforehand.
---
--- @return boolean true on success
--- @return string? error message on failure
local function unshare(): boolean, string
  local ok, err = unix.unshare(unix.CLONE_NEWNET)
  if not ok then return false, errno.wrap(err, "unshare") end
  return true
end

--- Bring `name` up in the current net namespace (reads flags, sets
--- IFF_UP, writes them back). Idempotent.
---
--- @param name string interface name (e.g. "lo")
--- @return boolean true on success
--- @return string? error message on failure
local function bring_up(name: string): boolean, string
  local flags, err = get_flags(name)
  if not flags then
    return false, errno.wrap(err, "bring_up " .. name)
  end
  return set_flags(name, flags | (unix.IFF_UP))
end

--- Bring `name` down in the current net namespace. Idempotent.
---
--- @param name string interface name
--- @return boolean true on success
--- @return string? error message on failure
local function bring_down(name: string): boolean, string
  local flags, err = get_flags(name)
  if not flags then
    return false, errno.wrap(err, "bring_down " .. name)
  end
  return set_flags(name, flags & ~ (unix.IFF_UP))
end

--- Close a file descriptor previously returned by open().
---
--- @param fd integer file descriptor
--- @return boolean true on success
--- @return string? error message on failure
local function close(fd: integer): boolean, string
  local ok, err = unix.close(fd)
  if not ok then return false, errno.wrap(err, "close") end
  return true
end

local record NetnsModule
  open: function(pid: integer): integer | nil, string
  enter: function(fd: integer): boolean, string
  unshare_user: function(): boolean, string
  unshare: function(): boolean, string
  bring_up: function(name: string): boolean, string
  bring_down: function(name: string): boolean, string
  get_flags: function(name: string): integer | nil, string
  set_flags: function(name: string, flags: integer): boolean, string
  close: function(fd: integer): boolean, string
end

local M: NetnsModule = {
  open = open,
  enter = enter,
  unshare_user = unshare_user,
  unshare = unshare,
  bring_up = bring_up,
  bring_down = bring_down,
  get_flags = get_flags,
  set_flags = set_flags,
  close = close,
}

return M
