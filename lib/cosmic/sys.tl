--- System information utilities.
--- Wraps cosmo system functions for OS and architecture queries.
local cosmo = require("cosmo")

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

local record SysModule
  host_os: function(): string
  host_isa: function(): string
  platform: function(): string
end

local M: SysModule = {
  host_os = host_os,
  host_isa = host_isa,
  platform = platform,
}

return M
