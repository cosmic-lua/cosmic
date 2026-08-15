--- Tarball extraction scenario: cosmic.tar.extract on a synthetic
--- .tar.gz tree. Every `--make fetch` (and the CI repro lane) unpacks
--- pinned archives through this path — C gunzip of the whole archive
--- into one string, then a pure-Lua 512-byte-header walk with
--- per-entry slicing and an fs.write per file. Brackets against
--- embed_extract_tree, which is the same job through the C zip path.
--- Extraction overwrites the same destination every op, so the
--- workload is stationary.

local compress = require("cosmic.compress")
local fs = require("cosmic.fs")
local tar = require("cosmic.tar")
local pt = require("_perf.perf_types")

local BLOCK = 512
local DIRS = 20
local FILES_PER_DIR = 5
local MODE_644 = 420 -- 0644 in octal

local tmpdir: string

--- Base directory for scratch files.
--- @return string An existing writable directory
local function tmp_base(): string
  return os.getenv("TEST_TMPDIR") or os.getenv("TMPDIR") or "/tmp"
end

--- Render one octal header field: width-1 zero-padded digits plus the
--- terminating NUL, the layout tar's octal_field parses back.
--- @param n integer The value
--- @param width integer The field width in bytes, NUL included
--- @return string The rendered field
local function octal_field(n: integer, width: integer): string
  return string.format("%0" .. tostring(width - 1) .. "o", n) .. "\0"
end

--- Build one 512-byte ustar header with a valid checksum.
--- @param name string The entry name
--- @param size integer The payload size in bytes
--- @param typeflag string "0" for a file, "5" for a directory
--- @return string The header block
local function tar_header(name: string, size: integer, typeflag: string): string
  local fields: {string} = {
    name .. string.rep("\0", 100 - #name), -- name, bytes 1-100
    octal_field(MODE_644, 8), -- mode, 101-108
    octal_field(0, 8), -- uid, 109-116
    octal_field(0, 8), -- gid, 117-124
    octal_field(size, 12), -- size, 125-136
    octal_field(0, 12), -- mtime, 137-148
    string.rep(" ", 8), -- chksum placeholder, 149-156
    typeflag, -- 157
    string.rep("\0", 100), -- linkname, 158-257
    "ustar\000", -- magic, 258-263
    "00", -- version, 264-265
  }
  local head = table.concat(fields)
  head = head .. string.rep("\0", BLOCK - #head)
  local sum = 0
  for i = 1, BLOCK do
    sum = sum + head:byte(i)
  end
  local chksum = string.format("%06o", sum) .. "\0 "
  return head:sub(1, 148) .. chksum .. head:sub(157)
end

--- Deterministic content for one file entry, a few hundred bytes.
--- @param dir integer The directory index
--- @param file integer The file index
--- @return string The content
local function file_content(dir: integer, file: integer): string
  return string.rep(
    string.format("file %d in dir %d: the quick brown fox\n", file, dir), 8)
end

--- Build the whole archive: DIRS directories of FILES_PER_DIR files
--- each, gzip-compressed so extraction exercises the same
--- gunzip-then-walk path `--make fetch` uses.
--- @return string | nil The .tar.gz bytes, or nil on failure
--- @return string? Error message on failure
local function build_archive(): string | nil, string
  local parts: {string} = {}
  for d = 1, DIRS do
    local dirname = string.format("d%02d/", d)
    parts[#parts + 1] = tar_header(dirname, 0, "5")
    for f = 1, FILES_PER_DIR do
      local content = file_content(d, f)
      parts[#parts + 1] = tar_header(dirname .. "f" .. f .. ".txt", #content, "0")
      local pad = (BLOCK - #content % BLOCK) % BLOCK
      parts[#parts + 1] = content .. string.rep("\0", pad)
    end
  end
  parts[#parts + 1] = string.rep("\0", BLOCK * 2) -- end-of-archive marker
  return compress.compress(table.concat(parts), {format = "gzip"})
end

local function scenarios(): {pt.Scenario}, string
  local dir, terr = fs.temp_dir(fs.join(tmp_base(), "perf-tar-XXXXXX"))
  if dir == nil then
    return nil, "temp_dir: " .. tostring(terr)
  end
  tmpdir = dir
  local archive_bytes, aerr = build_archive()
  if archive_bytes == nil then
    return nil, "gzip: " .. tostring(aerr)
  end
  local archive = fs.join(tmpdir, "tree.tar.gz")
  local wok, werr = fs.write(archive, archive_bytes)
  if not wok then
    return nil, "write archive: " .. tostring(werr)
  end
  local dest = fs.join(tmpdir, "out")

  return {
    {
      name = "tar_extract_tree",
      fn = function(_: any): any
        local ok, err = tar.extract(archive, dest)
        if not ok then
          return "extract failed: " .. tostring(err)
        end
        return true
      end,
      check = function(_: any, res: any): boolean, string
        if res ~= true then
          return false, tostring(res)
        end
        local first = fs.read(fs.join(dest, "d01/f1.txt"))
        if first ~= file_content(1, 1) then
          return false, "first file content mismatch"
        end
        local last = fs.read(fs.join(dest,
            string.format("d%02d/f%d.txt", DIRS, FILES_PER_DIR)))
        if last ~= file_content(DIRS, FILES_PER_DIR) then
          return false, "last file content mismatch"
        end
        if not fs.is_dir(fs.join(dest, string.format("d%02d", DIRS))) then
          return false, "directory entry missing"
        end
        return true
      end,
    },
  }
end

local function cleanup()
  if tmpdir then
    local _ok, _err = fs.remove_all(tmpdir)
    tmpdir = nil
  end
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
