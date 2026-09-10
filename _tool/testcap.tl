--- Declared host-capability probes for test files.
---
--- A test opts in with a header such as `--- requires: loopback-listen`.
--- Only these probes may classify a file as unavailable; child stderr and
--- exit codes are never interpreted as host capability evidence.

local fs = require("cosmic.fs")
local net = require("cosmic.net")
local sys = require("cosmic.sys")

local record Availability
  available: boolean
  detail: string
end

local record Requirement
  name: string
  required_linux_ci: boolean
  probe: function(temp_dir: string): Availability
end

local function probe_loopback(_temp_dir: string): Availability
  local socket, err = net.listen_tcp("127.0.0.1", 0)
  if not socket then
    return {available = false, detail = tostring(err or "loopback bind failed")}
  end
  local ok, cerr = socket:close()
  if not ok then
    return {available = false, detail = tostring(cerr or "loopback close failed")}
  end
  return {available = true, detail = ""}
end

local function probe_assimilation(_temp_dir: string): Availability
  if sys.host_os() == "linux" then return {available = true, detail = ""} end
  return {
    available = false,
    detail = "APE assimilation is supported by the Linux CI host",
  }
end

local function probe_nanosecond_timestamps(temp_dir: string): Availability
  local path = fs.join(temp_dir, "timestamp-capability")
  local ok, err = fs.write(path, "probe")
  if not ok then return {available = false, detail = tostring(err)} end
  ok, err = fs.set_times(path, {
      atime = {secs = 1234567890, nsecs = 123456789},
      mtime = {secs = 1234567890, nsecs = 987654321},
    })
  if not ok then return {available = false, detail = tostring(err)} end
  local st, serr = fs.stat(path)
  if not st then return {available = false, detail = tostring(serr)} end
  local at, mt = st:access_time(), st:modify_time()
  if at.nsecs ~= 123456789 or mt.nsecs ~= 987654321 then
    return {
      available = false,
      detail = "filesystem rounded nanosecond timestamps",
    }
  end
  return {available = true, detail = ""}
end

local REQUIREMENTS < const >: {string: Requirement} = {
  ["loopback-listen"] = {
    name = "loopback-listen",
    required_linux_ci = true,
    probe = probe_loopback,
  },
  ["ape-assimilation"] = {
    name = "ape-assimilation",
    required_linux_ci = true,
    probe = probe_assimilation,
  },
  ["nanosecond-timestamps"] = {
    name = "nanosecond-timestamps",
    required_linux_ci = true,
    probe = probe_nanosecond_timestamps,
  },
}

--- Read `--- requires:` declarations from a test source header.
--- @param source string Test source bytes
--- @return {string} Capability identifiers in declaration order
local function declarations(source: string): {string}
  local out: {string} = {}
  for line in source:gmatch("[^\n]+") do
    local names = line:match("^%-%-%- requires:%s*(.-)%s*$")
    if names then
      for name in names:gmatch("%S+") do out[#out + 1] = name end
    elseif line ~= "" and not line:match("^#!") and not line:match("^%-%-") then
      break
    end
  end
  return out
end

--- Resolve one declared identifier with a real probe or a test override.
--- @param name string Declared identifier
--- @param temp_dir string Per-test scratch directory
--- @param overrides {string: Availability}? Hermetic probe answers for tests
--- @return Availability|nil Probe answer, nil for an unknown identifier
--- @return string Configuration error for an unknown identifier
local function probe(name: string, temp_dir: string,
    overrides?: {string: Availability}): Availability | nil, string
  if overrides and overrides[name] then return overrides[name] end
  local requirement = REQUIREMENTS[name]
  if not requirement then return nil, "unknown test capability: " .. name end
  return requirement.probe(temp_dir)
end

--- Is absence of this declared capability fatal under the selected profile?
--- @param name string Known identifier
--- @param profile string `local` or `linux-ci`
--- @return boolean True when absence must fail
--- @return string Profile or identifier error
local function absence_is_fatal(name: string, profile: string): boolean, string
  local requirement = REQUIREMENTS[name]
  if not requirement then return false, "unknown test capability: " .. name end
  if profile == "local" then return false, "" end
  if profile == "linux-ci" then return requirement.required_linux_ci, "" end
  return false, "unknown test capability profile: " .. profile
end

local record TestCapModule
  type Availability = Availability
  REQUIREMENTS: {string: Requirement}
  declarations: function(source: string): {string}
  probe: function(name: string, temp_dir: string,
  overrides?: {string: Availability}): Availability | nil, string
  absence_is_fatal: function(name: string, profile: string): boolean, string
end

local M: TestCapModule = {
  REQUIREMENTS = REQUIREMENTS,
  declarations = declarations,
  probe = probe,
  absence_is_fatal = absence_is_fatal,
}

return M
