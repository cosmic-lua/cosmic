#!/usr/bin/env lua
--- In-process `.tar.gz` extraction: unpack a gzipped tarball without a
--- host `tar`.
---
--- It began as the stage pipeline's replacement for `tar -xzmf`
--- and moved here when `--make` needed it too: `_make` unpacks pinned
--- archives at runtime, the artifact floor is `cosmic/**`, and a module
--- a built binary requires has to be inside it. Making it public is the
--- honest consequence — position is the manifest — and "unpack a
--- tarball" is a battery beside `cosmic.zip` and `cosmic.compress`
--- rather than something peculiar to this repo's build.
---
--- Writes through `cosmic.fs` rather than `_build`'s bootstrap-portable
--- shim: that shim exists for a bootstrap predating the 2026.07
--- error-convention release, and a module the artifact floor carries
--- cannot depend on `_build` at all. The stage pipeline keeps its own
--- shim for the paths that still run under the pinned binary.
---
--- FAILURE CONTRACT: extraction is not atomic. Entries are written as
--- they are read, so a failure partway through leaves `destdir` holding
--- everything up to the refused entry. Extract into a fresh directory
--- you own and treat it as scratch on failure -- the pin pipeline does
--- exactly that, unpacking into a staging directory it removes. Making
--- this atomic would mean staging and moving a whole tree, which is a
--- larger change than the guarantee is worth while every caller already
--- stages.
---
--- Covers what pinned release tarballs actually contain — the ustar/pax layouts git archive and GNU tar emit:
--- regular files, directories, symlinks, pax extended headers (path
--- override), and GNU longnames. Anything else fails loudly. Modes are
--- masked to 0777; mtimes and ownership are deliberately not restored
--- (the stage rule's pledge does not promise utimensat/chown — the same
--- policy `-m --no-same-owner` encodes for tar(1)).

local compress = require("cosmic.compress")
local fs = require("cosmic.fs")

local BLOCK = 512
--- Decompression cap: input integrity comes from the fetch rule's sha256
--- pin; this only keeps a corrupt archive from eating the build host.
--- Fetch caps downloads at 100 MiB compressed.
local MAX_TAR = 512 * 1024 * 1024

local record Header
  name: string
  mode: integer
  size: integer
  typeflag: string
  linkname: string
end

local function str_field(block: string, from: integer, len: integer): string
  local raw = block:sub(from, from + len - 1)
  return raw:match("^[^\0]*")
end

local function octal_field(block: string, from: integer, len: integer): integer
  local digits = block:sub(from, from + len - 1):match("([0-7]+)")
  if not digits then return 0 end
  return tonumber(digits, 8) as integer -- cast: octal digits parse integral
end

--- Verify the header checksum: the byte sum of the block with the
--- checksum field (bytes 149-156) read as spaces. Catches parser/block
--- desync and corruption with a loud error instead of garbage paths.
local function checksum_ok(block: string): boolean
  local stored = octal_field(block, 149, 8)
  local sum = 0
  for i = 1, BLOCK do
    if i >= 149 and i <= 156 then
      sum = sum + 32
    else
      sum = sum + block:byte(i)
    end
  end
  return sum == stored
end

local function parse_header(block: string): Header
  local name = str_field(block, 1, 100)
  local magic = block:sub(258, 262)
  if magic == "ustar" then
    local prefix = str_field(block, 346, 155)
    if prefix ~= "" then
      name = prefix .. "/" .. name
    end
  end
  return {
    name = name,
    mode = octal_field(block, 101, 8),
    size = octal_field(block, 125, 12),
    typeflag = block:sub(157, 157),
    linkname = str_field(block, 158, 100),
  }
end

--- Parse a pax extended header payload: "<len> <key>=<value>\n" records,
--- where <len> counts the whole record including itself.
local function parse_pax(data: string): {string: string}
  local out: {string: string} = {}
  local pos = 1
  while pos <= #data do
    local len_str = data:match("^(%d+) ", pos)
    local len = len_str and math.tointeger(tonumber(len_str))
    if not len or len <= 0 then break end
    local rec = data:sub(pos, pos + len - 1)
    local key, value = rec:match("^%d+ ([^=]+)=(.*)\n$")
    if key then
      out[key] = value
    end
    pos = pos + len
  end
  return out
end

--- Reject entry names that would escape the extraction root. The
--- predicate is fs.unsafe_entry_name — one guard for zip, tar and
--- embed. (This drops tar's old blanket backslash refusal: a
--- backslash now acts as a separator for the traversal check, same as
--- the other two formats, so `a\b.txt` extracts as a literal file
--- and `..\evil` is still refused.)
local unsafe_path = fs.unsafe_entry_name

--- Symlink targets must stay inside the tree: relative, no "..", no
--- control characters (same reasoning as `unsafe_path`).
local function unsafe_link_target(target: string): boolean
  if not target or target == "" then return true end
  if target:sub(1, 1) == "/" then return true end
  if target:find("%c") then return true end
  for component in (target .. "/"):gmatch("([^/]*)/") do
    if component == ".." then return true end
  end
  return false
end

local function write_entry(hdr: Header, name: string, payload: string,
    destdir: string): boolean, string
  if unsafe_path(name) then
    return false, "unsafe path in archive: " .. name
  end
  local dest = fs.join(destdir, name)
  local t = hdr.typeflag
  if t == "5" or name:sub(-1) == "/" then
    local ok, err = fs.make_dirs(dest)
    if not ok then
      return false, "mkdir " .. dest .. " failed: " .. (err or "unknown error")
    end
  elseif t == "0" or t == "\0" then
    local dok, derr = fs.make_dirs(fs.dirname(dest))
    if not dok then
      return false, "mkdir " .. fs.dirname(dest) .. " failed: " .. (derr or "unknown error")
    end
    local mode = hdr.mode % 512 -- permission bits only (0777 mask)
    if mode == 0 then mode = tonumber("644", 8) as integer end -- cast: octal is integral
    local ok, err = fs.write(dest, payload, mode)
    if not ok then
      return false, "write " .. dest .. " failed: " .. (err or "unknown error")
    end
  elseif t == "2" then
    if unsafe_link_target(hdr.linkname) then
      return false, "unsafe symlink target in archive: " .. name .. " -> " .. hdr.linkname
    end
    local dok, derr = fs.make_dirs(fs.dirname(dest))
    if not dok then
      return false, "mkdir " .. fs.dirname(dest) .. " failed: " .. (derr or "unknown error")
    end
    local ok, err = fs.symlink(hdr.linkname, dest)
    if not ok then
      return false, "symlink " .. dest .. " failed: " .. (err or "unknown error")
    end
  else
    return false, "unsupported tar entry type '" .. t .. "': " .. name
  end
  return true
end

--- Extract a gzip-compressed tarball into destdir.
--- @param archive string Path to the .tar.gz file
--- @param destdir string Directory to extract into (created if needed)
--- @return boolean true when every entry was written
--- @return string? Error message on failure
local function extract(archive: string, destdir: string): boolean, string
  local gz, read_err = fs.read(archive)
  if not gz then
    return false, "read " .. archive .. " failed: " .. (read_err or "unknown error")
  end
  local data, gz_err = compress.decompress(gz, {format = "gzip", max_output = MAX_TAR})
  if not data then
    return false, "gunzip " .. archive .. " failed: " .. (gz_err or "unknown error")
  end
  local ok_mk, mk_err = fs.make_dirs(destdir)
  if not ok_mk then
    return false, "mkdir " .. destdir .. " failed: " .. (mk_err or "unknown error")
  end

  local zero_block = string.rep("\0", BLOCK)
  local pos = 1
  local pending_path: string = nil -- pax 'x' path= or GNU 'L' longname
  while pos + BLOCK - 1 <= #data do
    local block = string.sub(data, pos, pos + BLOCK - 1)
    pos = pos + BLOCK
    if block == zero_block then
      return true -- end-of-archive marker
    end
    if not checksum_ok(block) then
      return false, "bad tar header checksum at offset " .. tostring(pos - BLOCK - 1)
    end
    local hdr = parse_header(block)
    if pos + hdr.size - 1 > #data then
      return false, "truncated archive: entry " .. hdr.name .. " exceeds data"
    end
    local payload = string.sub(data, pos, pos + hdr.size - 1)
    pos = pos + math.ceil(hdr.size / BLOCK) * BLOCK

    local t = hdr.typeflag
    if t == "x" then
      local pax = parse_pax(payload)
      if pax.path then pending_path = pax.path end
    elseif t == "L" then
      pending_path = payload:match("^[^\0]*")
    elseif t == "g" then
      -- global pax header (git archive stamps the commit here): ignore
    else
      local name = pending_path or hdr.name
      pending_path = nil
      local ok, err = write_entry(hdr, name, payload, destdir)
      if not ok then
        return false, err
      end
    end
  end
  -- Falling off the end without a terminator is a TRUNCATED archive,
  -- and accepting it was a silent partial success: a truncation landing
  -- on a 512-byte boundary after decompression leaves the loop with no
  -- entry to complain about and every entry so far written. gzip
  -- integrity and an upstream digest cover the accidental case, which
  -- is why nothing has tripped it -- but a public extractor should not
  -- report success over an archive it did not reach the end of.
  return false, "truncated archive: no end-of-archive marker in " .. archive
end

return {
  extract = extract,
  -- `unsafe_path` stays public because `cosmic.embed` and `--make
  -- fetch` guard archive-controlled names with the same rule, and one
  -- shared predicate is what keeps the two from disagreeing.
  -- `parse_pax` was public only so a test could call it; pax paths are
  -- covered through extraction now, and an export is a contract.
  unsafe_path = unsafe_path,
}
