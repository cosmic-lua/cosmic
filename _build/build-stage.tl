#!/usr/bin/env lua
-- ast-grep ignore: builds relative symlink paths
-- stage.lua: extract fetched archives based on version.lua format

local compress = require("cosmic.compress")
local fs = require("cosmic.fs")
local literal = require("cosmic.literal")
local fs_types = require("cosmic.fs.types")
local portable = require("_build.portable")
local proc = require("cosmic.proc")
local untar = require("_build.build-untar")
local zip = require("cosmic.zip")

local record PlatformSpec
  sha: string
  format: string
end

local record VersionSpec
  version: string
  format: string
  strip_components: number
  strip_prefix: string
  install: {string: string}
  remove: {string}
  links: {string: string}
  platforms: {string: PlatformSpec}
end

local function move_contents(source_dir: string, dest_dir: string): boolean, string
  local dir0, dir_err = fs.opendir(source_dir)
  if not dir0 then
    return nil, "failed to open directory " .. source_dir .. ": " .. (dir_err or "unknown error")
  end
  local dir = dir0 as fs_types.Dir -- cast: record union after guard
  while true do
    local name = dir:read()
    if not name then break end
    if name ~= "." and name ~= ".." then
      local src = fs.join(source_dir, name)
      local dst = fs.join(dest_dir, name)
      -- rename() cannot replace a non-empty directory, so a restage over a
      -- stale destination (e.g. after the build tooling itself changed and
      -- invalidated .staged) must clear the old entry first.
      fs.rmrf(dst)
      local ok, err = fs.rename(src, dst)
      if not ok then
        return nil, "failed to move " .. src .. " to " .. dst .. ": " .. (err or "unknown error")
      end
    end
  end
  return true
end

local function strip_components(source_dir: string, dest_dir: string, strip: number): boolean, string
  if strip == 0 then
    return move_contents(source_dir, dest_dir)
  end

  local current = source_dir
  for _ = 1, strip do
    local dir0, dir_err = fs.opendir(current)
    if not dir0 then
      return nil, "failed to open directory " .. current .. ": " .. (dir_err or "unknown error")
    end
    local dir = dir0 as fs_types.Dir -- cast: record union after guard -- cast: record union after guard
    local entries: {string} = {}
    while true do
      local name = dir:read()
      if not name then break end
      if name ~= "." and name ~= ".." then
        table.insert(entries, name)
      end
    end
    if #entries ~= 1 then
      -- cast: %d needs integer
      return nil, string.format("strip %d: expected 1 entry at level, found %d", strip as integer, #entries)
    end
    current = fs.join(current, entries[1])
  end

  local st = fs.stat(current)
  if st and (st as fs_types.Stat):is_dir() then -- cast: mixed-representation Stat
    return move_contents(current, dest_dir)
  else
    local dst = fs.join(dest_dir, fs.basename(current))
    return fs.rename(current, dst)
  end
end

-- Extraction is in-process (#732): cosmic.zip / build.build-untar /
-- cosmic.compress instead of spawning host unzip/tar/gunzip, so the
-- stage rule's unveil set carries no host-toolchain grants.
local function extract_zip(archive: string, dest_dir: string, strip: number): boolean, string
  local temp_dir = fs.mkdtemp(fs.join(fs.dirname(dest_dir), ".stage_XXXXXX"))
  local reader, open_err = zip.reader(archive)
  if not reader then
    fs.rmrf(temp_dir)
    return nil, "zip open failed: " .. (open_err or "unknown error")
  end
  local r = reader as zip.Reader -- cast: record union after guard
  local ok, err = zip.extract(r, temp_dir)
  r:close()
  if not ok then
    fs.rmrf(temp_dir)
    return nil, "zip extract failed: " .. (err or "unknown error")
  end
  ok, err = strip_components(temp_dir, dest_dir, strip)
  fs.rmrf(temp_dir)
  return ok, err
end

local function extract_targz(archive: string, dest_dir: string, strip: number): boolean, string
  local temp_dir = fs.mkdtemp(fs.join(fs.dirname(dest_dir), ".stage_XXXXXX"))
  local ok, err = untar.extract(archive, temp_dir)
  if not ok then
    fs.rmrf(temp_dir)
    return nil, err
  end
  ok, err = strip_components(temp_dir, dest_dir, strip)
  fs.rmrf(temp_dir)
  return ok, err
end

local function copy_binary(archive: string, dest_dir: string, module_name: string): boolean, string
  local bin_dir = fs.join(dest_dir, "bin")
  fs.makedirs(bin_dir)
  local dest = fs.join(bin_dir, module_name)
  local content, read_err = fs.read(archive)
  if not content then
    return nil, "failed to open " .. archive .. ": " .. (read_err or "unknown error")
  end
  local ok, write_err = portable.write_file(dest, content, tonumber("755", 8))
  if not ok then
    return nil, "failed to create " .. dest .. ": " .. (write_err or "unknown error")
  end
  return true
end

local function extract_gz(archive: string, dest_dir: string, module_name: string): boolean, string
  local bin_dir = fs.join(dest_dir, "bin")
  fs.makedirs(bin_dir)
  local dest = fs.join(bin_dir, module_name)
  local body, read_err = fs.read(archive)
  if not body then
    return nil, "read " .. archive .. " failed: " .. (read_err or "unknown error")
  end
  local content, gz_err = compress.decompress(body, {format = "gzip"})
  if not content then
    return nil, "gunzip " .. archive .. " failed: " .. (gz_err or "unknown error")
  end
  local ok, write_err = portable.write_file(dest, content, tonumber("755", 8))
  if not ok then
    return nil, "failed to create " .. dest .. ": " .. (write_err or "unknown error")
  end
  return true
end

local function install_files(source_dir: string, dest_dir: string, strip_prefix: string): boolean, string
  local src = source_dir
  if strip_prefix then
    src = fs.join(source_dir, strip_prefix)
  end
  return move_contents(src, dest_dir)
end

local type ExtractFn = function(string, string, number): boolean, string

local function extract_and_install(
    extract_fn: ExtractFn,
    archive: string,
    stage_dir: string,
    strip: number,
    strip_prefix: string
  ): boolean, string
  local temp_dir = fs.mkdtemp(fs.join(fs.dirname(stage_dir), ".stage_XXXXXX"))
  local ok, err = extract_fn(archive, temp_dir, strip)
  if ok then
    ok, err = install_files(temp_dir, stage_dir, strip_prefix)
  end
  fs.rmrf(temp_dir)
  return ok, err
end

--- Validate a relative path component for use within the stage directory.
--- Rejects empty paths, absolute paths (leading /), and paths containing
--- `..` components. Returns an error string on failure, nil on success.
local function validate_stage_path(p: string): string
  if not p or p == "" then
    return "path must not be empty"
  end
  if p:sub(1, 1) == "/" then
    return "path must not be absolute: " .. p
  end
  for component in (p .. "/"):gmatch("([^/]*)/") do
    if component == ".." then
      return "path must not contain '..': " .. p
    end
  end
  return nil
end

--- Validate a symlink target: must be relative and contain no `..` components.
local function validate_link_target(target: string): string
  if not target or target == "" then
    return "symlink target must not be empty"
  end
  if target:sub(1, 1) == "/" then
    return "symlink target must not be absolute: " .. target
  end
  for component in (target .. "/"):gmatch("([^/]*)/") do
    if component == ".." then
      return "symlink target must not contain '..': " .. target
    end
  end
  return nil
end

local function apply_install(stage_dir: string, install: {string: string}): boolean, string
  for src, dst in pairs(install) do
    local src_err = validate_stage_path(src)
    if src_err then
      return nil, "install src invalid: " .. src_err
    end
    local dst_err = validate_stage_path(dst)
    if dst_err then
      return nil, "install dst invalid: " .. dst_err
    end
    local src_path = fs.join(stage_dir, src)
    local dst_path = fs.join(stage_dir, dst)
    fs.makedirs(fs.dirname(dst_path))
    local ok, err = fs.rename(src_path, dst_path)
    if not ok then
      return nil, string.format("install %s -> %s failed: %s", src, dst, err or "unknown error")
    end
  end
  return true
end

local function apply_remove(stage_dir: string, remove: {string}): boolean, string
  for _, file in ipairs(remove) do
    local file_err = validate_stage_path(file)
    if file_err then
      return nil, "remove path invalid: " .. file_err
    end
    local file_path = fs.join(stage_dir, file)
    fs.rmrf(file_path)
  end
  return true
end

local function apply_links(stage_dir: string, links: {string: string}): boolean, string
  for link, target in pairs(links) do
    local link_err = validate_stage_path(link)
    if link_err then
      return nil, "link path invalid: " .. link_err
    end
    local target_err = validate_link_target(target)
    if target_err then
      return nil, "link target invalid: " .. target_err
    end
    local link_path = fs.join(stage_dir, link)
    fs.makedirs(fs.dirname(link_path))
    fs.rmrf(link_path)
    local ok, err = fs.symlink(target, link_path)
    if not ok then
      return nil, string.format("link %s -> %s failed: %s", link, target, err or "unknown error")
    end
  end
  return true
end

local function find_archive(fetch_dir: string, format: string): string, string
  if format == "binary" or format == "gz" then
    return fs.join(fetch_dir, "binary")
  end
  local extension: string = nil
  if format == "zip" then
    extension = ".zip"
  elseif format == "tar.gz" then
    extension = ".tar.gz"
  end
  local dir0, dir_err = fs.opendir(fetch_dir)
  if not dir0 then
    return nil, "failed to open " .. fetch_dir .. ": " .. (dir_err or "unknown error")
  end
  local dir = dir0 as fs_types.Dir -- cast: record union after guard
  while true do
    local name = dir:read()
    if not name then break end
    if name ~= "." and name ~= ".." then
      if not extension or name:sub(-#extension) == extension then
        return fs.join(fetch_dir, name)
      end
    end
  end
  return nil, "no archive found in " .. fetch_dir
end

local function main(version_file: string, platform: string, input: string, output: string): boolean, string
  if not version_file or not platform or not input or not output then
    return nil, "usage: stage.lua <version_file> <platform> <input.fetched> <output.staged>"
  end

  local stage_o = os.getenv("STAGE_O")
  if not stage_o then
    return nil, "STAGE_O env var required"
  end

  -- the make rule passes o/<module>/.versioned, a symlink to the
  -- module's *.pin.tl; resolve it here so error messages name the real
  -- file and the recipe needs no host readlink (#732)
  local resolved = fs.readlink(version_file)
  if resolved then
    version_file = resolved
  end

  -- READ, not run (3g): a pin is data. This was `dofile`, which made
  -- every fetch and every stage execute the file that says what to
  -- fetch — the one thing a pin exists to make unnecessary. Same reader
  -- `cosmic --make fetch` uses, so the grammar is enforced identically
  -- from both sides.
  -- cast: the reader returns a plain table; the spec shape is this file's
  local spec, perr = literal.of_file(version_file, "pin") as(VersionSpec, string)
  if not spec then
    return nil, "failed to read " .. version_file .. ": " .. tostring(perr)
  end

  local plat = spec.platforms[platform] or spec.platforms["*"]
  if not plat then
    return nil, "unknown platform: " .. platform
  end

  local format = spec.format or plat.format or "binary"
  local strip = spec.strip_components or 1

  -- derive module name from output path: o/<module>/.staged
  local output_dir = fs.dirname(output)
  local module_name = fs.basename(output_dir)

  -- input is now a directory; find the archive inside
  local archive, err = find_archive(input, format)
  if not archive then
    return nil, err
  end

  local version_sha = spec.version .. "-" .. plat.sha

  local stage_dir = fs.join(stage_o, module_name, version_sha)
  local ok_mk, err_mk = fs.makedirs(stage_dir)
  if not ok_mk then
    return nil, "makedirs failed for " .. stage_dir .. ": " .. tostring(err_mk)
  end

  local ok: boolean
  if format == "zip" then
    ok, err = extract_and_install(extract_zip, archive, stage_dir, strip, spec.strip_prefix)
  elseif format == "tar.gz" then
    ok, err = extract_and_install(extract_targz, archive, stage_dir, strip, spec.strip_prefix)
  elseif format == "binary" then
    ok, err = copy_binary(archive, stage_dir, module_name)
  elseif format == "gz" then
    ok, err = extract_gz(archive, stage_dir, module_name)
  else
    return nil, "unknown format: " .. format
  end

  if not ok then
    return nil, err
  end

  -- apply post-extraction transforms from version.lua
  if spec.remove then
    ok, err = apply_remove(stage_dir, spec.remove)
    if not ok then return nil, err end
  end
  if spec.install then
    ok, err = apply_install(stage_dir, spec.install)
    if not ok then return nil, err end
  end
  if spec.links then
    ok, err = apply_links(stage_dir, spec.links)
    if not ok then return nil, err end
  end

  -- format: STAGE  module @ version-sha_prefix
  local sha_prefix = plat.sha:sub(1, 7)
  io.stderr:write(string.format("□ STAGE  %s @ %s-%s\n", module_name, spec.version, sha_prefix))

  -- create symlink: output -> staged/<module>/<version-sha>
  -- output is o/<module>/.staged, staged is o/staged/<module>/<ver>-<sha>
  fs.rmrf(output)
  fs.makedirs(output_dir)
  local stage_o_basename = fs.basename(stage_o)
  local rel_path = "../" .. stage_o_basename .. "/" .. module_name .. "/" .. version_sha
  local ok_symlink, symlink_err = fs.symlink(rel_path, output)
  if not ok_symlink then
    return nil, "failed to symlink: " .. rel_path .. " -> " .. output .. ": " .. (symlink_err or "unknown error")
  end

  return true
end

if proc.is_main() then
  local ok, err = main(arg[1], arg[2], arg[3], arg[4])
  if not ok then
    io.stderr:write("error: " .. tostring(err) .. "\n")
    os.exit(1)
  end
end

return {
  validate_stage_path = validate_stage_path,
  validate_link_target = validate_link_target,
}
