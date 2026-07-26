#!/usr/bin/env lua
-- ast-grep ignore: builds relative symlink paths
-- The Makefile path's fetcher: download a pin's archive, verify it,
-- land it under `$FETCH_O/<module>/<version>-<sha>/<archive>`, and
-- point a `<module>/current` symlink at it.
--
-- Pin RESOLUTION is not here: `_make.pin` reads the committed
-- `*_pin.tl` files for both this pipeline and `cosmic --make fetch`, so
-- there is one interpretation of a pin's url template and one place a
-- placeholder can mean something. What stays here is this pipeline's
-- own landing convention, which `--make fetch` does not share: it lands
-- a pin's products beside the pin instead.

local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local pin = require("_make.pin")
local portable = require("_build.portable")
local proc = require("cosmic.proc")
local fetch = require("cosmic.fetch")

local function download(url: string): string, string
  local result = fetch.fetch(url, {
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

  -- the make rule passes o/<module>/.versioned, a symlink to the
  -- module's *_pin.tl; resolve it here so error messages name the real
  -- file and the recipe needs no host readlink
  local resolved = fs.readlink(version_file)
  if resolved then
    version_file = resolved
  end

  -- READ, not run: a pin is data. This was `dofile`, which made
  -- every fetch and every stage execute the file that says what to
  -- fetch — the one thing a pin exists to make unnecessary.
  local resolved_pin, perr = pin.read(version_file, platform)
  if not resolved_pin then
    return nil, "failed to read " .. version_file .. ": " .. tostring(perr)
  end
  local spec = resolved_pin as pin.Pin -- cast: record union after the guard

  local body, err = download(spec.url)
  if not body then
    return nil, err
  end

  local verify_ok: boolean
  verify_ok, err = verify_sha256(body, spec.sha256)
  if not verify_ok then
    return nil, err
  end

  -- derive module name from output path: o/<module>/.fetched
  local module_name = fs.basename(output_dir)

  -- build archive path: $FETCH_O/<module>/<version>-<sha>/<archive>
  -- for binary/gz format, use fixed name "binary" so staging knows what to look for
  -- The shared reader already refused a url whose tail is not a usable
  -- file name, so what is left here is this pipeline's naming: an
  -- unpacked archive keeps its own name, raw bytes land as `binary` so
  -- staging knows what to look for without consulting the pin.
  local format = spec.format or "tar.gz"
  local archive_name = fs.basename(spec.output)
  if format == "binary" or format == "gz" then
    archive_name = "binary"
  end
  local version_sha = (spec.version or "0") .. "-" .. spec.sha256
  local archive_dir = fs.join(fetch_o, module_name, version_sha)
  local archive_path = fs.join(archive_dir, archive_name)

  io.stderr:write(string.format("↓ FETCH  %s\n", spec.url))

  fs.makedirs(archive_dir)

  local barf_ok, barf_err = portable.write_file(archive_path, body, tonumber("644", 8))
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

-- Nothing to export: url building and archive-name validation moved to
-- the shared reader (`_make.pin`), where both pipelines get them, and
-- `_make/pins_test.tl` gates them against the REAL committed pins
-- rather than against strings.
return {}
