--- Unpacking a pinned archive.
---
--- A pin names bytes; some of those bytes are an archive, and what the
--- build needs is what is inside it — `tl.lua` from the Teal tarball,
--- `make` from the cosmos zip. So a pin may declare a `format`, and
--- `fetch` unpacks it beside the archive it verified.
---
--- Unpacking happens only after the digest matched. That ordering is
--- the whole point: an archive is a program for a decompressor, and
--- running one on unverified bytes is exactly what pinning exists to
--- prevent.
---
--- The tar reader is `cosmic.tar`, which already refuses
--- escaping entry names and link targets. It lives under `_build`
--- because the make-driven build needed it first; when that path
--- retires the reader moves rather than being rewritten.

local fs = require("cosmic.fs")
local untar = require("cosmic.tar")
local zip = require("cosmic.zip")

--- Copy a tree, dropping the first `strip` path segments.
---
--- An archive of a tagged release wraps everything in one directory
--- named for the tag, which changes on every bump — `strip_components`
--- is how a pin says "that wrapper is not part of the path". A file
--- whose path is entirely wrapper is skipped rather than landing at the
--- destination root under its own name.
--- @param from string Directory holding the extracted archive
--- @param to string Directory to populate
--- @param strip integer Leading segments to drop
--- @param out {string} Collects each file's path relative to `to`
--- @return boolean, string Success, or false plus the reason
local function strip_into(from: string, to: string, strip: integer,
    out: {string}): boolean, string
  local prefix = string.rep("[^/]+/", strip)
  local failure: string = nil
  local ok, werr = fs.visit(from, function(e: fs.Entry): fs.WalkAction
      local path, st = e.path, e.stat
      if st:is_link() then
        -- Loudly, not silently. `cosmic.tar` deliberately preserves
        -- archive-internal symlinks (relative, no `..`), and this walk
        -- copied only regular files -- so a pinned tarball using the
        -- ordinary `lib/libfoo.so -> libfoo.so.1` shape unpacked,
        -- reported satisfied, and left the links missing. The failure
        -- then surfaced far from fetch, as an absence.
        --
        -- Refusing rather than re-creating them is deliberate: fetched
        -- trees being symlink-free is currently what keeps `exec`'s
        -- lexical root check honest (a symlink under `o/` would pass a
        -- prefix test and be followed at spawn). Carrying them needs
        -- that check resolved through realpath first.
        failure = path:sub(#from + 2) ..
        ": the archive contains a symlink, which a pinned tree does not carry"
        return "stop"
      end
      if not st:is_file() then
        return nil
      end
      local rel = path:sub(#from + 2)
      local stripped = strip > 0 and (rel:gsub("^" .. prefix, "")) or rel
      if stripped == rel and strip > 0 then
        -- Entirely wrapper: nothing left once the prefix is dropped.
        return nil
      end
      local dest = fs.join(to, stripped)
      out[#out + 1] = stripped
      local mok, merr = fs.make_dirs(fs.dirname(dest))
      if not mok then
        failure = "cannot create " .. fs.dirname(dest) .. ": " ..
        (merr or "unknown error")
        return "stop"
      end
      local body, rerr = fs.read(path)
      if not body then
        failure = "cannot read " .. path .. ": " .. (rerr or "unknown error")
        return "stop"
      end
      local wok, wrerr = fs.write(dest, body)
      if not wok then
        failure = "cannot write " .. dest .. ": " .. (wrerr or "unknown error")
        return "stop"
      end
      -- The archive's mode matters for anything executable, which is
      -- the case that motivated unpacking at all (`make`). WalkStat does
      -- not carry it, so the source is stat'd for the bits.
      local src = fs.stat(path)
      if src then
        local _ok, _err = fs.set_mode(dest, src:mode() & tonumber("777", 8))
      end
      return nil
    end)
  if failure then
    return false, "make: " .. failure
  end
  if not ok then
    return false, "make: cannot walk " .. from .. ": " .. (werr or "unknown error")
  end
  return true
end

--- Unpack `archive` into `dest`, by declared format.
--- @param archive string Path to the verified archive
--- @param dest string Directory to unpack into
--- @param format string "zip" or "tar.gz"
--- @param strip integer Leading path segments to drop
--- @return {string}|nil The unpacked paths, relative to `dest`
--- @return string The error message
local function unpack(archive: string, dest: string, format: string,
    strip: integer): {string} | nil, string
  local staging = fs.join(dest, ".unpack")
  local _ok, _err = fs.remove_all(staging)
  local mok, merr = fs.make_dirs(staging)
  if not mok then
    return nil, "make: cannot create " .. staging .. ": " ..
    (merr or "unknown error")
  end
  local ok: boolean = false
  local err: string = nil
  if format == "zip" then
    local reader, oerr = zip.open(archive)
    -- Truthiness, not `is zip.Archive`: the tree's Archive is a
    -- wrapper table while the pinned record types it as the binding
    -- userdata, and an `is` test compiled against the pinned record
    -- would reject the table at cold start (#996 transition).
    if not reader then
      local _ok, _err = fs.remove_all(staging)
      return nil, "make: cannot open " .. archive .. ": " ..
      (oerr or "unknown error")
    end
    local r = reader
    ok, err = zip.extract(r, staging)
    r:close()
  elseif format == "tar.gz" then
    ok, err = untar.extract(archive, staging)
  else
    local _ok, _err = fs.remove_all(staging)
    return nil, "make: " .. archive .. ": unknown format '" .. format ..
    "'; a pin unpacks as zip or tar.gz"
  end
  if not ok then
    local _ok, _err = fs.remove_all(staging)
    return nil, "make: cannot unpack " .. archive .. ": " ..
    (err or "unknown error")
  end
  local produced: {string} = {}
  local sok, serr = strip_into(staging, dest, strip, produced)
  local _ok, _err = fs.remove_all(staging)
  if not sok then
    return nil, serr
  end
  return produced
end

local record ExtractModule
  unpack: function(archive: string, dest: string, format: string,
  strip: integer): {string} | nil, string
end

local M: ExtractModule = {
  unpack = unpack,
}

return M
