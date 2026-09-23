--- The host triple `bin/zig.pin` and zig's own release tarballs use --
--- `<arch>-<os>` -- derived from `uname(2)`'s raw sysname and machine
--- (`sys.uname`), normalized the way `bin/zig`'s shell `case`s did.

local sys = require("cosmic.sys")

local record Host
end

--- Maps `uname`'s raw sysname to the name `bin/zig.pin` uses.
local function os_of(sysname: string): string | nil
  if sysname == "Linux" then
    return "linux"
  end
  if sysname == "Darwin" then
    return "macos"
  end
  return nil
end

--- Maps `uname`'s raw machine to the name `bin/zig.pin` uses.
local function arch_of(machine: string): string | nil
  if machine == "x86_64" or machine == "amd64" then
    return "x86_64"
  end
  if machine == "aarch64" or machine == "arm64" then
    return "aarch64"
  end
  return nil
end

--- `<arch>-<os>` from raw `sysname` and `machine`, as `uname(2)` (or a
--- test's own stand-ins) reports them.
function Host.triple(sysname: string, machine: string): string | nil, string
  local os = os_of(sysname)
  if os == nil then
    return nil, "unsupported host " .. sysname .. "; cosmic builds on Linux and macOS"
  end
  local arch = arch_of(machine)
  if arch == nil then
    return nil, "unsupported host cpu " .. machine
  end
  return arch .. "-" .. os, ""
end

--- This host's triple, read from `sys.uname`.
function Host.detect(): string | nil, string
  local names, trouble = sys.uname()
  if names == nil then
    return nil, "uname: " .. trouble
  end
  return Host.triple(names.sysname, names.machine)
end

return Host
