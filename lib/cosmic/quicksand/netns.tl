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
local Errno = require("cosmic.errno").Errno

local IFREQ_UNION_SIZE < const > = 24
local IFNAMSIZ < const > = 16 -- mirrors unix.IFNAMSIZ; kernel ABI constant

local function wrap_err(err: any, fallback: string): string
  if not err then return fallback end
  local e = err as Errno
  if e.doc then return e:doc() end
  return tostring(err)
end

--- Build a `struct ifreq` for SIOCGIFFLAGS/SIOCSIFFLAGS: char
--- ifr_name[IFNAMSIZ] at offset 0, int16 ifr_flags at offset IFNAMSIZ,
--- padded to the largest union member.
local function build_ifreq(name: string, flags: integer): string
  assert(#name < IFNAMSIZ, "interface name too long")
  local name_field = name .. string.rep("\0", IFNAMSIZ - #name)
  local flags_field = string.pack("<i2", flags)
  return name_field .. flags_field
  .. string.rep("\0", IFREQ_UNION_SIZE - #flags_field)
end

--- Parse the 16-bit flags field out of an ifreq returned by ioctl().
local function parse_ifreq_flags(ifr: string): integer
  return (string.unpack("<i2", ifr, IFNAMSIZ + 1)) as integer
end

--- Open an AF_INET dgram socket for the SIOC* interface ioctls.
--- SOCK_CLOEXEC: don't leak this short-lived control socket into any
--- exec'd child.
local function control_socket(): integer, string
  local sk, err = unix.socket(
    unix.AF_INET, unix.SOCK_DGRAM | unix.SOCK_CLOEXEC, 0)
  if not sk then return nil, wrap_err(err, "socket failed") end
  return sk as integer
end

--- Read the current IFF_* flags on `name` in the current net namespace.
---
--- @param name string interface name (e.g. "lo")
--- @return integer? flags bitmask on success
--- @return string? error message on failure
local function get_flags(name: string): integer, string
  if #name >= IFNAMSIZ then return nil, "interface name too long" end
  local sk, err = control_socket()
  if not sk then return nil, err end
  local result, ioerr = unix.ioctl(sk, unix.SIOCGIFFLAGS, build_ifreq(name, 0))
  unix.close(sk)
  if not result then return nil, wrap_err(ioerr, "SIOCGIFFLAGS failed") end
  return parse_ifreq_flags(result as string)
end

--- Set the IFF_* flags on `name` in the current net namespace.
---
--- @param name string interface name
--- @param flags integer IFF_* bitmask to write
--- @return boolean true on success
--- @return string? error message on failure
local function set_flags(name: string, flags: integer): boolean, string
  if #name >= IFNAMSIZ then return false, "interface name too long" end
  local sk, err = control_socket()
  if not sk then return false, err end
  local ok, ioerr = unix.ioctl(sk, unix.SIOCSIFFLAGS, build_ifreq(name, flags))
  unix.close(sk)
  if not ok then return false, wrap_err(ioerr, "SIOCSIFFLAGS failed") end
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
local function open(pid: integer): integer, string
  local tag = pid and tostring(pid) or "self"
  local fd, err = unix.open("/proc/" .. tag .. "/ns/net",
    unix.O_RDONLY | unix.O_CLOEXEC)
  if not fd then return nil, wrap_err(err, "netns.open failed") end
  return fd as integer
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
  if not ok then return false, wrap_err(err, "setns failed") end
  return true
end

--- Create and enter a new network namespace in the current thread.
--- Equivalent to `unshare(CLONE_NEWNET)`; requires either root or
--- CLONE_NEWUSER beforehand.
---
--- @return boolean true on success
--- @return string? error message on failure
local function unshare(): boolean, string
  local ok, err = unix.unshare(unix.CLONE_NEWNET)
  if not ok then return false, wrap_err(err, "unshare failed") end
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
    return false, wrap_err(err, "bring_up " .. name .. " failed")
  end
  return set_flags(name, flags | (unix.IFF_UP as integer))
end

--- Bring `name` down in the current net namespace. Idempotent.
---
--- @param name string interface name
--- @return boolean true on success
--- @return string? error message on failure
local function bring_down(name: string): boolean, string
  local flags, err = get_flags(name)
  if not flags then
    return false, wrap_err(err, "bring_down " .. name .. " failed")
  end
  return set_flags(name, flags & ~ (unix.IFF_UP as integer))
end

--- Close a file descriptor previously returned by open().
---
--- @param fd integer file descriptor
--- @return boolean true on success
--- @return string? error message on failure
local function close(fd: integer): boolean, string
  local ok, err = unix.close(fd)
  if not ok then return false, wrap_err(err, "close failed") end
  return true
end

local record NetnsModule
  open: function(pid: integer): integer, string
  enter: function(fd: integer): boolean, string
  unshare: function(): boolean, string
  bring_up: function(name: string): boolean, string
  bring_down: function(name: string): boolean, string
  get_flags: function(name: string): integer, string
  set_flags: function(name: string, flags: integer): boolean, string
  close: function(fd: integer): boolean, string
end

local M: NetnsModule = {
  open = open,
  enter = enter,
  unshare = unshare,
  bring_up = bring_up,
  bring_down = bring_down,
  get_flags = get_flags,
  set_flags = set_flags,
  close = close,
}

return M
