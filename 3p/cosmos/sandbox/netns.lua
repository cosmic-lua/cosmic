--- cosmo.sandbox.netns: network-namespace helpers.
---
--- Composable pieces built on the `unix.*` namespace + ioctl
--- primitives. Each function returns `nil, unix.Errno` on failure,
--- matching the rest of the cosmo lunix API.
---
--- Typical flow inside a forked child:
---
---     local netns = require "cosmo.sandbox.netns"
---     assert(unix.unshare(unix.CLONE_NEWNET))
---     assert(netns.bring_up("lo"))
---     -- loopback is now reachable at 127.0.0.1 in this namespace
---
--- Typical flow in the parent (to enter a child's namespace fd-wise):
---
---     local fd = assert(netns.open(child_pid))
---     assert(unix.setns(fd, unix.CLONE_NEWNET))
---
--- Linux-only.

local unix = require "unix"

local M = {}

--- netns.build_ifreq(name, flags) → string
---
--- Build a `struct ifreq` suitable for passing to SIOCSIFFLAGS /
--- SIOCGIFFLAGS. The Linux layout is char ifr_name[16] followed by a
--- 24-byte union; we populate ifr_name and ifr_flags at offsets 0 and
--- 16 respectively. `name` must be at most IFNAMSIZ-1 bytes; `flags`
--- is an int16 bitmask of IFF_* values.
function M.build_ifreq(name, flags)
  assert(type(name) == "string", "interface name must be a string")
  assert(#name < unix.IFNAMSIZ, "interface name too long")
  local name_field = name .. string.rep("\0", unix.IFNAMSIZ - #name)
  local flags_field = string.pack("<i2", flags or 0)
  -- Pad the union to 24 bytes (largest union member).
  return name_field .. flags_field .. string.rep("\0", 24 - #flags_field)
end

--- netns.parse_ifreq_flags(ifr) → int
---
--- Parse the 16-bit flags field out of an ifreq returned by ioctl().
function M.parse_ifreq_flags(ifr)
  return (string.unpack("<i2", ifr, unix.IFNAMSIZ + 1))
end

--- netns.control_socket() → fd | nil, unix.Errno
---
--- Open an AF_INET dgram socket suitable as the "fd" argument to the
--- SIOC* interface-configuration ioctls. The caller owns the fd and
--- should close it.
function M.control_socket()
  -- SOCK_CLOEXEC: prevent this short-lived control socket from leaking
  -- into any exec'd child (e.g. the sandboxed command) via an accidental
  -- fork/exec ordering change.
  return unix.socket(unix.AF_INET, unix.SOCK_DGRAM | unix.SOCK_CLOEXEC, 0)
end

--- netns.get_flags(name) → flags:int | nil, unix.Errno
---
--- Read the current IFF_* flags on `name` in the current net namespace.
function M.get_flags(name)
  local sk, err = M.control_socket()
  if not sk then return nil, err end
  local result, ioerr = unix.ioctl(sk, unix.SIOCGIFFLAGS,
                                   M.build_ifreq(name, 0))
  unix.close(sk)
  if not result then return nil, ioerr end
  return M.parse_ifreq_flags(result)
end

--- netns.set_flags(name, flags) → true | nil, unix.Errno
---
--- Set the IFF_* flags on `name` in the current net namespace.
function M.set_flags(name, flags)
  local sk, err = M.control_socket()
  if not sk then return nil, err end
  local ok, ioerr = unix.ioctl(sk, unix.SIOCSIFFLAGS,
                               M.build_ifreq(name, flags))
  unix.close(sk)
  if not ok then return nil, ioerr end
  return true
end

--- netns.bring_up(name) → true | nil, unix.Errno
---
--- Bring `name` up in the current net namespace (reads flags, sets
--- IFF_UP, writes them back). Idempotent.
function M.bring_up(name)
  local flags, err = M.get_flags(name)
  if not flags then return nil, err end
  return M.set_flags(name, flags | unix.IFF_UP)
end

--- netns.bring_down(name) → true | nil, unix.Errno
---
--- Bring `name` down in the current net namespace. Idempotent.
function M.bring_down(name)
  local flags, err = M.get_flags(name)
  if not flags then return nil, err end
  return M.set_flags(name, flags & ~unix.IFF_UP)
end

--- netns.open([pid]) → fd:int | nil, unix.Errno
---
--- Open the network namespace of `pid` as a file descriptor. For the
--- current process, omit `pid` (or pass nil/"self").
function M.open(pid)
  local tag = pid and tostring(pid) or "self"
  -- O_CLOEXEC: a namespace fd that leaks across exec into the sandboxed
  -- child gives it a setns(2) handle back to the parent network namespace —
  -- a direct sandbox escape. setns() calls in THIS process are unaffected
  -- (CLOEXEC only fires across exec, not fork or plain syscalls).
  return unix.open("/proc/" .. tag .. "/ns/net",
                   unix.O_RDONLY | unix.O_CLOEXEC)
end

return M
