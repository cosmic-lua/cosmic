#!/usr/bin/env lua
-- Trust-root make extractor (#756 item 6). bin/make runs this under the
-- sha-pinned bootstrap cosmic BEFORE any make binary exists, to produce
-- bin/cosmo-make from the sha-pinned cosmos.zip — no host unzip, and no
-- separate landlock-make release asset. Nothing else can be assumed at
-- that point: the tree is not compiled, so requires are limited to the
-- bootstrap's EMBEDDED cosmic.* stdlib (never build.* — bin/make invokes
-- this with LUA_PATH=";;" to keep that honest).
local fetch = require("cosmic.fetch")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local proc = require("cosmic.proc")
local zip = require("cosmic.zip")

local record PlatformSpec
  sha: string
end

local record VersionSpec
  version: string
  url: string
  platforms: {string: PlatformSpec}
end

--- URL and pinned sha256 resolved from a `*.pin.tl` spec.
local record Pin
  url: string
  sha: string
end

--- Load a 3p `*.pin.tl`.
---
--- The one place left that `dofile`s a pin, and it cannot be otherwise
--- yet: this runs at BOOTSTRAP time, before the tree is compiled and
--- with `LUA_PATH=";;"` pinning its requires to the freshly-fetched
--- bootstrap's embedded stdlib — which is a released binary, and
--- `cosmic.literal` is newer than any release. It converts when the
--- bootstrap pin next moves. Everything downstream of here (fetch,
--- stage, the version stamp) reads its pins instead of running them.
--- @param path string Path to the `*.pin.tl`
--- @return VersionSpec | nil The parsed spec, or nil on error
--- @return string? Error message if loading failed
local function load_spec(path: string): VersionSpec | nil, string
  -- cast: pcall returns any
  local ok, spec = pcall(dofile, path) as(boolean, VersionSpec)
  if not ok then
    return nil, "failed to load " .. path .. ": " .. tostring(spec)
  end
  return spec
end

--- Resolve the archive URL and pinned sha from a version spec. Only the
--- "*" platform is supported: cosmos.zip is a fat archive, so its pin is
--- platform-independent.
--- @param spec VersionSpec The parsed pin spec
--- @return Pin | nil The resolved url + sha, or nil on error
--- @return string? Error message if the spec is incomplete
local function resolve_pin(spec: VersionSpec): Pin | nil, string
  if not spec.version or not spec.url then
    return nil, "version spec missing version or url"
  end
  local plat: PlatformSpec
  if spec.platforms then
    plat = spec.platforms["*"]
  end
  if not plat or not plat.sha then
    return nil, "version spec missing platforms['*'].sha"
  end
  return {
    url = (spec.url:gsub("{version}", spec.version)),
    sha = plat.sha,
  }
end

--- Download a URL into memory, with retries (the same fetch options as
--- build-fetch, which cannot be required here — see the header).
--- @param url string The URL to download
--- @return string | nil The response body, or nil on error
--- @return string? Error message if the download failed
local function download(url: string): string | nil, string
  local result = fetch.fetch(url, {
      headers = {["User-Agent"] = "curl/8.0"},
      maxresponse = 100 * 1024 * 1024,
      max_attempts = 8,
    })
  if not result.ok then
    return nil, "fetch failed: " .. result.error
  end
  if result.status ~= 200 then
    return nil, "fetch status " .. tostring(result.status)
  end
  return result.body
end

--- Read one member out of an in-memory zip archive.
--- @param archive string The zip archive bytes
--- @param name string The member name to extract
--- @return string | nil The member's contents, or nil on error
--- @return string? Error message if opening or reading failed
local function extract_member(archive: string, name: string): string | nil, string
  local reader, open_err = zip.from(archive)
  if not reader then
    return nil, "zip open failed: " .. (open_err or "unknown error")
  end
  local r = reader as zip.Reader -- cast: record union after guard
  local data, read_err = r:read(name)
  r:close()
  if not data then
    return nil, "zip member " .. name .. ": " .. (read_err or "not found")
  end
  return data
end

--- Atomically write an executable file (mode 0755), creating parent
--- directories as needed.
--- @param path string Destination path
--- @param data string File contents
--- @return boolean true when the file was written
--- @return string? Error message if writing failed
local function write_executable(path: string, data: string): boolean, string
  local dir = fs.dirname(path)
  if dir and dir ~= "" then
    local made, mkdir_err = fs.makedirs(dir)
    if not made then
      return false, "makedirs " .. dir .. ": " .. (mkdir_err or "unknown error")
    end
  end
  -- cast: tonumber of an octal literal is non-nil
  local mode = tonumber("755", 8) as integer
  local wrote, write_err = fs.write_atomic(path, data, mode)
  if not wrote then
    return false, "write " .. path .. ": " .. (write_err or "unknown error")
  end
  return true
end

--- Fetch the pinned archive named by a `*.pin.tl`, verify its sha256,
--- and install one member of it as an executable.
--- @param version_file string Path to the version.lua pin
--- @param member string Zip member to extract (e.g. "make")
--- @param output string Destination path for the executable
--- @return boolean true when the member was installed
--- @return string? Error message on failure
local function main(version_file: string, member: string, output: string): boolean, string
  if not version_file or not member or not output then
    return false, "usage: make-boot.tl <version.lua> <member> <output>"
  end
  local spec, spec_err = load_spec(version_file)
  if not spec then
    return false, spec_err
  end
  -- cast: record union after guard
  local pin, pin_err = resolve_pin(spec as VersionSpec)
  if not pin then
    return false, pin_err
  end
  local p = pin as Pin -- cast: record union after guard
  io.stderr:write("↓ FETCH  " .. p.url .. "\n")
  local body, dl_err = download(p.url)
  if not body then
    return false, dl_err
  end
  local actual = hash.sha256_hex(body)
  if actual ~= string.lower(p.sha) then
    return false, string.format(
      "sha256 mismatch for %s: expected %s, got %s", p.url, p.sha, actual)
  end
  local data, extract_err = extract_member(body, member)
  if not data then
    return false, extract_err
  end
  local ok, write_err = write_executable(output, data)
  if not ok then
    return false, write_err
  end
  return true
end

if proc.is_main() then
  local ok, err = main(arg[1], arg[2], arg[3])
  if not ok then
    io.stderr:write("error: " .. err .. "\n")
    os.exit(1)
  end
end

return {
  load_spec = load_spec,
  resolve_pin = resolve_pin,
  extract_member = extract_member,
  write_executable = write_executable,
  main = main,
}
