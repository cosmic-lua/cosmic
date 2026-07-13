--- System information utilities.
--- Wraps cosmo system functions for OS and architecture queries.
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str

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

--- Operating system name as reported by `host_os`.
--- These are the normalized cosmic names, not the raw cosmopolitan tokens:
--- macOS reports as "macos" (the C layer returns "XNU"), and bare-metal as
--- "metal".
local enum HostOs
  "linux"
  "macos"
  "windows"
  "freebsd"
  "openbsd"
  "netbsd"
  "metal"
  "unknown"
end

-- Cosmopolitan's GetHostOs() returns tokens that do not all match the names
-- cosmic documents ("XNU" vs "macos"). Translate in the wrapper so callers
-- compare against a single, stable vocabulary across the six fat-binary OSes.
local host_os_names: {string: HostOs} = {
  linux = "linux",
  xnu = "macos",
  windows = "windows",
  freebsd = "freebsd",
  openbsd = "openbsd",
  netbsd = "netbsd",
  metal = "metal",
}

--- Normalize a raw cosmopolitan OS token (e.g. "XNU", "Linux") to a HostOs.
--- Unknown tokens are passed through lowercased.
--- @param raw string The raw OS token from cosmo.GetHostOs()
--- @return HostOs The normalized operating system name
local function normalize_host_os(raw: string): HostOs
  local lowered = raw:lower()
  return host_os_names[lowered] or (lowered as HostOs)
end

--- Get the operating system name.
--- Returns one of: "linux", "macos", "windows", "freebsd", "openbsd",
--- "netbsd", "metal" — or "unknown" if the C layer recognizes none
--- (GetHostOs returns nil then; unreachable on shipped fat-binary
--- targets, but the type admits it honestly).
--- @return HostOs The operating system name
local function host_os(): HostOs
  return normalize_host_os(cosmo.GetHostOs() or "unknown")
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
--- @return number | nil The configuration value
--- @return string? Error message on failure
local function sysconf(name: number): number | nil, string
  local val, err = unix.sysconf(name) as(number, any)
  if not val then
    return nil, errstr(err, "sysconf")
  end
  return val
end

--- Number of processors currently online (available to run threads).
--- @return number | nil The online processor count
--- @return string? Error message on failure
local function nproc(): number | nil, string
  return sysconf(unix.SC_NPROCESSORS_ONLN)
end

--- Number of processors configured in the system.
--- May exceed `nproc()` when some processors are offline.
--- @return number | nil The configured processor count
--- @return string? Error message on failure
local function nproc_configured(): number | nil, string
  return sysconf(unix.SC_NPROCESSORS_CONF)
end

--- Memory page size in bytes.
--- @return number | nil The page size in bytes
--- @return string? Error message on failure
local function page_size(): number | nil, string
  return sysconf(unix.SC_PAGESIZE)
end

--- Get operating system and hardware identification.
--- Returns a `Uname` record with `sysname`, `nodename`, `release`, `version`,
--- `machine`, and `domainname` fields. Returns nil plus an error message on failure.
--- @return Uname | nil The system identification record
--- @return string? Error message on failure
local function uname(): Uname | nil, string
  local uts, err = unix.uname() as(Uname, any)
  if not uts then
    return nil, errstr(err, "uname")
  end
  return uts
end

local record SysModule
  -- Exported so callers can name/cast the fallible uname result.
  type Uname = Uname

  -- sysconf(3) name constants
  SC_ARG_MAX: number
  SC_CHILD_MAX: number
  SC_CLK_TCK: number
  SC_OPEN_MAX: number
  SC_PAGESIZE: number
  SC_NPROCESSORS_CONF: number
  SC_NPROCESSORS_ONLN: number

  host_os: function(): HostOs
  normalize_host_os: function(raw: string): HostOs
  host_isa: function(): string
  platform: function(): string
  sysconf: function(name: number): number | nil, string
  nproc: function(): number | nil, string
  nproc_configured: function(): number | nil, string
  page_size: function(): number | nil, string
  uname: function(): Uname | nil, string
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
  normalize_host_os = normalize_host_os,
  host_isa = host_isa,
  platform = platform,
  sysconf = sysconf,
  nproc = nproc,
  nproc_configured = nproc_configured,
  page_size = page_size,
  uname = uname,
}

return M
