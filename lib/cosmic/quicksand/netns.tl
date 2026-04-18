--- Linux network-namespace primitives.
---
--- Thin typed wrappers over cosmo.sandbox.netns plus the pieces of
--- cosmo.unix needed to join a netns without pulling in the full
--- lunix namespace. All calls are Linux-only and return cosmic's
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
local cnetns = require("cosmo.sandbox.netns")
local unix = require("cosmo.unix")
local Errno = require("cosmic.errno").Errno

local function wrap_err(err: any, fallback: string): string
  if not err then return fallback end
  local e = err as Errno
  if e.doc then return e:doc() end
  return tostring(err)
end

--- Open the network namespace of `pid` as a file descriptor.
--- Pass nil (or omit) to open the current process's net namespace.
--- Caller owns the fd and must close() it when done.
---
--- @param pid integer? target pid, or nil for self
--- @return integer? fd on success
--- @return string? error message on failure
local function open(pid: integer): integer, string
  local fd, err = cnetns.open(pid) as (integer, any)
  if not fd then return nil, wrap_err(err, "netns.open failed") end
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
  local u = unix as {string: any}
  local ok, err = (u.setns as function(integer, integer): boolean, any)(
    fd, u.CLONE_NEWNET as integer)
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
  local u = unix as {string: any}
  local ok, err = (u.unshare as function(integer): boolean, any)(
    u.CLONE_NEWNET as integer)
  if not ok then return false, wrap_err(err, "unshare failed") end
  return true
end

--- Bring `name` up in the current net namespace. Idempotent.
---
--- @param name string interface name (e.g. "lo")
--- @return boolean true on success
--- @return string? error message on failure
local function bring_up(name: string): boolean, string
  local ok, err = cnetns.bring_up(name) as (boolean, any)
  if not ok then return false, wrap_err(err, "bring_up " .. name .. " failed") end
  return true
end

--- Bring `name` down in the current net namespace. Idempotent.
---
--- @param name string interface name
--- @return boolean true on success
--- @return string? error message on failure
local function bring_down(name: string): boolean, string
  local ok, err = cnetns.bring_down(name) as (boolean, any)
  if not ok then return false, wrap_err(err, "bring_down " .. name .. " failed") end
  return true
end

--- Close a file descriptor previously returned by open().
---
--- @param fd integer file descriptor
--- @return boolean true on success
--- @return string? error message on failure
local function close(fd: integer): boolean, string
  local ok, err = unix.close(fd) as (boolean, any)
  if not ok then return false, wrap_err(err, "close failed") end
  return true
end

local record NetnsModule
  open:       function(pid: integer): integer, string
  enter:      function(fd: integer): boolean, string
  unshare:    function(): boolean, string
  bring_up:   function(name: string): boolean, string
  bring_down: function(name: string): boolean, string
  close:      function(fd: integer): boolean, string
end

local M: NetnsModule = {
  open = open,
  enter = enter,
  unshare = unshare,
  bring_up = bring_up,
  bring_down = bring_down,
  close = close,
}

return M
