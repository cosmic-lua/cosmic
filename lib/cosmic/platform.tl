--- Native platform detection (OS and architecture).
--- Exposes the current platform as simple string fields, using
--- cosmopolitan internals rather than shelling out to uname.
--- OS names use uname-style conventions: "darwin" (not "macos").
local cosmo = require("cosmo")

--- Map cosmo OS names to uname-style names.
local os_map: {string: string} = {
  linux = "linux",
  macos = "darwin",
  windows = "windows",
  freebsd = "freebsd",
  openbsd = "openbsd",
  netbsd = "netbsd",
}

local raw_os = cosmo.GetHostOs():lower()
local raw_arch = cosmo.GetHostIsa():lower()

local record PlatformModule
  --- Operating system: "linux", "darwin", "windows", "freebsd", "openbsd", "netbsd".
  os: string
  --- CPU architecture: "x86_64", "aarch64".
  arch: string
end

local M: PlatformModule = {
  os = os_map[raw_os] or raw_os,
  arch = raw_arch,
}

return M
