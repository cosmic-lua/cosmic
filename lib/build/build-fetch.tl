#!/usr/bin/env lua
-- ast-grep ignore: builds relative symlink paths
local cio = require("cosmic.io")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local proc = require("cosmic.proc")
local fetch = require("cosmic.fetch")

local record PlatformSpec
  sha: string
  format: string
end

local record VersionSpec
  version: string
  url: string
  format: string
  platforms: {string:PlatformSpec}
end

local function interpolate(template: string, vars: {string:string}): string
  return (template:gsub("{([%w_]+)}", function(key: string): string
    return vars[key] or ""
  end))
end

local function build_url(spec: VersionSpec, platform: string): string, string
  local plat = spec.platforms[platform] or spec.platforms["*"]
  if not plat then
    return nil, "unknown platform: " .. platform
  end

  local vars: {string:string} = {platform = platform}
  for k, v in pairs(spec as {string:any}) do
    if type(v) ~= "table" then
      vars[k] = tostring(v)
    end
  end
  for k, v in pairs(plat as {string:any}) do
    vars[k] = tostring(v)
  end

  return interpolate(spec.url, vars)
end

local function download(url: string): string, string
  local result = fetch.Fetch(url, {
    headers = {["User-Agent"] = "curl/8.0"},
    maxresponse = 100 * 1024 * 1024,
    max_attempts = 8,
  })

  if not result.ok then return nil, "fetch failed: " .. result.error end
  if result.status ~= 200 then return nil, "fetch status " .. tostring(result.status) end
  return result.body
end

local function verify_sha256(content: string, expected: string): boolean, string
  local actual = hash.sha256_hex(content)
  if actual == expected:lower() then return true end
  return nil, string.format("sha256 mismatch: expected %s, got %s", expected, actual)
end

local function main(version_file: string, platform: string, output: string): boolean, string
  if not version_file or not platform or not output then
    return nil, "usage: fetch.lua <version_file> <platform> <output>"
  end

  local output_dir = fs.dirname(output)
  local fetch_o = os.getenv("FETCH_O")
  if not fetch_o then
    return nil, "FETCH_O env var required"
  end

  local ok, spec = pcall(dofile, version_file) as (boolean, VersionSpec)
  if not ok then
    return nil, "failed to load " .. version_file .. ": " .. tostring(spec)
  end

  local plat = spec.platforms[platform] or spec.platforms["*"]
  if not plat then
    return nil, "unknown platform: " .. platform
  end

  local url, url_err = build_url(spec, platform)
  if not url then
    return nil, url_err
  end

  local body, err = download(url)
  if not body then
    return nil, err
  end

  local verify_ok: boolean
  verify_ok, err = verify_sha256(body, plat.sha)
  if not verify_ok then
    return nil, err
  end

  -- derive module name from output path: o/<module>/.fetched
  local module_name = fs.basename(output_dir)

  -- build archive path: $FETCH_O/<module>/<version>-<sha>/<archive>
  -- for binary/gz format, use fixed name "binary" so staging knows what to look for
  local format = spec.format or plat.format or "tar.gz"
  local archive_name: string
  if format == "binary" or format == "gz" then
    archive_name = "binary"
  else
    archive_name = url:match("([^/]+)$")
  end
  local version_sha = spec.version .. "-" .. plat.sha
  local archive_dir = fs.join(fetch_o, module_name, version_sha)
  local archive_path = fs.join(archive_dir, archive_name)

  io.stderr:write(string.format("↓ FETCH  %s\n", url))

  fs.makedirs(archive_dir)

  local barf_ok, barf_err = cio.barf(archive_path, body, tonumber("644", 8))
  if not barf_ok then
    return nil, "failed to write " .. archive_path .. ": " .. (barf_err or "unknown error")
  end

  -- remove old symlink/file if exists, create relative symlink
  -- output is o/<module>/.fetched -> o/fetched/<module>/<ver>-<sha>/
  fs.unlink(output)
  local fetch_o_basename = fs.basename(fetch_o)
  local rel_path = "../" .. fetch_o_basename .. "/" .. module_name .. "/" .. version_sha
  local symlink_ok, symlink_err = fs.symlink(rel_path, output)
  if not symlink_ok then
    return nil, "failed to symlink: " .. rel_path .. " -> " .. output .. ": " .. (symlink_err or "unknown error")
  end

  return true
end

if proc.is_main() then
  local result, err = main(arg[1], arg[2], arg[3])
  if not result then
    io.stderr:write("error: " .. err .. "\n")
    os.exit(1)
  end
end

return {
  build_url = build_url,
}
