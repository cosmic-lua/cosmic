--- System information utilities.
--- Wraps cosmo system functions for OS and architecture queries.
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local Errno = require("cosmic.errno").Errno

--- Operating system and hardware identification returned by `uname`.
local record Uname
  --- Operating system name (e.g. "Linux").
  sysname: string
  --- Network node hostname.
  nodename: string
  --- Operating system release.
  release: string
  --- Operating system version.
  version: string
  --- Hardware identifier (e.g. "x86_64").
  machine: string
  --- NIS or YP domain name.
  domainname: string
end

--- Get the operating system name.
--- Returns lowercase strings: "linux", "macos", "windows", "freebsd", "openbsd", "netbsd".
--- @return string The operating system name
local function host_os(): string
  return cosmo.GetHostOs():lower()
end

--- Get the CPU architecture (instruction set architecture).
--- Returns lowercase strings: "x86_64", "aarch64".
--- @return string The CPU architecture
local function host_isa(): string
  return cosmo.GetHostIsa():lower()
end

--- Get the platform identifier combining OS and architecture.
--- Returns a string in the format "os-arch" (e.g., "linux-x86_64", "macos-aarch64").
--- @return string The platform identifier
local function platform(): string
  return host_os() .. "-" .. host_isa()
end

--- Query a runtime system configuration value.
--- `name` is one of the `unix.SC_*` constants (e.g. `unix.SC_PAGESIZE`,
--- `unix.SC_NPROCESSORS_ONLN`). Returns nil plus an error message on failure.
--- @param name number One of the unix.SC_* constants
--- @return number The configuration value
--- @return string? Error message on failure
local function sysconf(name: number): number, string
  local val, err = unix.sysconf(name) as(number, any)
  if not val then
    if err then
      local errno = err as Errno
      if errno.doc then
        return nil, "sysconf: " .. errno:doc()
      end
      return nil, "sysconf: " .. tostring(err)
    end
    return nil, "sysconf failed"
  end
  return val
end

--- Number of processors currently online (available to run threads).
--- @return number The online processor count
--- @return string? Error message on failure
local function nproc(): number, string
  return sysconf(unix.SC_NPROCESSORS_ONLN)
end

--- Number of processors configured in the system.
--- May exceed `nproc()` when some processors are offline.
--- @return number The configured processor count
--- @return string? Error message on failure
local function nproc_configured(): number, string
  return sysconf(unix.SC_NPROCESSORS_CONF)
end

--- Memory page size in bytes.
--- @return number The page size in bytes
--- @return string? Error message on failure
local function page_size(): number, string
  return sysconf(unix.SC_PAGESIZE)
end

--- Get operating system and hardware identification.
--- Returns a `Uname` record with `sysname`, `nodename`, `release`, `version`,
--- `machine`, and `domainname` fields. Returns nil plus an error message on failure.
--- @return Uname The system identification record
--- @return string? Error message on failure
local function uname(): Uname, string
  local uts, err = unix.uname() as(Uname, any)
  if not uts then
    if err then
      local errno = err as Errno
      if errno.doc then
        return nil, "uname: " .. errno:doc()
      end
      return nil, "uname: " .. tostring(err)
    end
    return nil, "uname failed"
  end
  return uts
end

local record SysModule
  -- sysconf(3) name constants
  SC_ARG_MAX: number
  SC_CHILD_MAX: number
  SC_CLK_TCK: number
  SC_OPEN_MAX: number
  SC_PAGESIZE: number
  SC_NPROCESSORS_CONF: number
  SC_NPROCESSORS_ONLN: number

  host_os: function(): string
  host_isa: function(): string
  platform: function(): string
  sysconf: function(name: number): number, string
  nproc: function(): number, string
  nproc_configured: function(): number, string
  page_size: function(): number, string
  uname: function(): Uname, string
end

local M: SysModule = {
  SC_ARG_MAX = unix.SC_ARG_MAX,
  SC_CHILD_MAX = unix.SC_CHILD_MAX,
  SC_CLK_TCK = unix.SC_CLK_TCK,
  SC_OPEN_MAX = unix.SC_OPEN_MAX,
  SC_PAGESIZE = unix.SC_PAGESIZE,
  SC_NPROCESSORS_CONF = unix.SC_NPROCESSORS_CONF,
  SC_NPROCESSORS_ONLN = unix.SC_NPROCESSORS_ONLN,

  host_os = host_os,
  host_isa = host_isa,
  platform = platform,
  sysconf = sysconf,
  nproc = nproc,
  nproc_configured = nproc_configured,
  page_size = page_size,
  uname = uname,
}

return M
