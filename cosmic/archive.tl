--- One entry point over whatever archive format a file turns out to
--- be: detected from its first bytes, walked through a single Entry
--- shape shared by tar (plain or compressed) and zip, and extracted to
--- a destination directory with the usual path-escape refusals a
--- caller expects from something unpacking bytes it did not write.

local Fs = require("cosmic.fs")
local Compress = require("cosmic.compress")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")

local record Archive
  --- Shared with `cosmic.tar`'s own Entry.kind; zip only ever produces
  --- "file" or "dir".
  type Kind = Tar.Kind

  record Entry
    path: string
    kind: Kind
    mode: integer
    size: integer
    mtime: integer
    --- A symlink's or hardlink's target; "" otherwise.
    linkpath: string
    open: function(Entry): Stream.Reader | nil, string
  end

  record ArchiveReader
    next: function(ArchiveReader): Entry | nil, string
    close: function(ArchiveReader): boolean, string
  end

  record ExtractOptions
    --- A literal prefix to drop from every path, or a number of
    --- leading path components to drop (tar's --strip-components).
    --- An entry the prefix does not match, or that runs out of
    --- components, is skipped.
    strip: string | integer
    --- Asked with a path already stripped; false skips the entry.
    filter: function(string): boolean
    --- "skip" (the default) or "create".
    links: string
  end
end

------------------------------------------------------------------
-- format detection
------------------------------------------------------------------

local GZIP_MAGIC <const> = "\31\139"
local XZ_MAGIC <const> = "\253" .. "7zXZ\0"
local BZIP2_MAGIC <const> = "BZh"
local ZIP_MAGIC <const> = "PK\3\4"
local EMPTY_ZIP_MAGIC <const> = "PK\5\6"

local function detect(head: string): string
  if head:sub(1, 4) == ZIP_MAGIC or head:sub(1, 4) == EMPTY_ZIP_MAGIC then return "zip" end
  if head:sub(1, 2) == GZIP_MAGIC then return "gzip" end
  if head:sub(1, 6) == XZ_MAGIC then return "xz" end
  if head:sub(1, 3) == BZIP2_MAGIC then return "bzip2" end
  if #head >= 262 and head:sub(258, 262) == "ustar" then return "tar" end
  return "unknown"
end

------------------------------------------------------------------
-- a uniform ArchiveReader over a Tar.TarReader or a Zip.ZipReader
------------------------------------------------------------------

local function wrap_tar(tr: Tar.TarReader, closer: function(): boolean, string): Archive.ArchiveReader
  local ar: Archive.ArchiveReader = {}
  ar.next = function(_self: Archive.ArchiveReader): Archive.Entry | nil, string
    local e, trouble = tr:next()
    if e == nil then return nil, trouble end
    local out: Archive.Entry = {
      path = e.path, kind = e.kind, mode = e.mode, size = e.size,
      mtime = e.mtime, linkpath = e.linkpath,
    }
    out.open = function(_o: Archive.Entry): Stream.Reader | nil, string
      return e:open(), ""
    end
    return out, ""
  end
  ar.close = function(_self: Archive.ArchiveReader): boolean, string
    return closer()
  end
  return ar
end

local function wrap_zip(zr: Zip.ZipReader): Archive.ArchiveReader
  local entries = zr:entries()
  local at = 0
  local ar: Archive.ArchiveReader = {}
  ar.next = function(_self: Archive.ArchiveReader): Archive.Entry | nil, string
    at = at + 1
    if at > #entries then return nil, "" end
    local e = entries[at]
    local out: Archive.Entry = {
      path = e.path, kind = e.kind as Archive.Kind, mode = e.mode, size = e.size,
      mtime = e.mtime, linkpath = "",
    }
    out.open = function(_o: Archive.Entry): Stream.Reader | nil, string
      return e:open()
    end
    return out, ""
  end
  ar.close = function(_self: Archive.ArchiveReader): boolean, string
    return zr:close()
  end
  return ar
end

--- Detects `path`'s format from its first bytes and returns a reader
--- over its entries, uniform whether it turns out to be a zip, a
--- plain ustar tar, or a tar compressed with gzip, xz, or bzip2. A
--- compressed format whose decoder `cosmic.compress` does not have
--- yet fails with a message naming it.
function Archive.open(path: string): Archive.ArchiveReader | nil, string
  local fd, trouble = Fs.open_read(path)
  if fd == nil then return nil, trouble end
  local head, htrouble = Fs.take(fd, 262)
  Fs.close(fd)
  if head == nil then return nil, htrouble end
  local kind = detect(head)
  if kind == "zip" then
    local zr, ztrouble = Zip.open(path)
    if zr == nil then return nil, ztrouble end
    return wrap_zip(zr), ""
  end
  if kind == "tar" then
    local raw, otrouble = Stream.open(path)
    if raw == nil then return nil, otrouble end
    return wrap_tar(Tar.reader(raw), function(): boolean, string return raw:close() end), ""
  end
  if kind == "gzip" or kind == "xz" or kind == "bzip2" then
    local raw, otrouble = Stream.open(path)
    if raw == nil then return nil, otrouble end
    local codec: Compress.Stream
    local ctrouble: string
    if kind == "gzip" then
      codec, ctrouble = Compress.inflater("gzip")
    elseif kind == "xz" then
      codec, ctrouble = Compress.xz_decoder()
    else
      codec, ctrouble = Compress.bz2_decoder()
    end
    if codec == nil then
      raw:close()
      return nil, "archive: " .. path .. ": " .. ctrouble
    end
    local transformed = Stream.transform(raw, codec as Stream.CodecStream)
    return wrap_tar(Tar.reader(transformed), function(): boolean, string return transformed:close() end), ""
  end
  return nil, "archive: " .. path .. ": not a recognized archive format"
end

--- Every entry of the archive at `path`.
function Archive.list(path: string): {Archive.Entry} | nil, string
  local reader, trouble = Archive.open(path)
  if reader == nil then return nil, trouble end
  local out: {Archive.Entry} = {}
  while true do
    local entry, etrouble = reader:next()
    if entry == nil then
      reader:close()
      if etrouble ~= "" then return nil, etrouble end
      return out, ""
    end
    out[#out + 1] = entry
  end
end

------------------------------------------------------------------
-- extraction
------------------------------------------------------------------

--- Whether `path` has a drive letter ("C:") or a UNC prefix ("\\\\"):
--- Windows path forms that a `/`-only escape check would miss.
local function has_drive_or_unc(path: string): boolean
  if path:sub(1, 2):match("^%a:$") ~= nil then return true end
  if path:sub(1, 2) == "\\\\" then return true end
  return false
end

--- False for an absolute path, a `\`-separated or drive/UNC path, or
--- one with a `..` component -- the archive path itself, before
--- `strip` is applied, since `strip` only removes a prefix or leading
--- components and cannot make an escaping path safe. `\` is refused
--- outright, along with drive letters and UNC prefixes, since none of
--- this format's writers put one in a path on purpose.
local function safe_relative(path: string): boolean
  if path == "" or path:sub(1, 1) == "/" then return false end
  if path:find("\\", 1, true) ~= nil then return false end
  if has_drive_or_unc(path) then return false end
  for segment in (path .. "/"):gmatch("([^/]*)/") do
    if segment == ".." then return false end
  end
  return true
end

local function apply_strip(path: string, strip: string | integer | nil): string | nil
  if strip == nil then return path end
  if strip is string then
    if path:sub(1, #strip) ~= strip then return nil end
    return (path:sub(#strip + 1):gsub("^/+", ""))
  end
  local n = strip as integer
  local rest = path
  for _ = 1, n do
    local slash = rest:find("/", 1, true)
    if slash == nil then return nil end
    rest = rest:sub(slash + 1)
  end
  return rest
end

--- Whether a symlink at `rel_dir`/... with `target` (relative or
--- absolute) stays inside the extraction root, tracked as a lexical
--- depth rather than by resolving real paths, since the destination
--- need not exist yet.
local function stays_inside(rel_dir: string, target: string): boolean
  if target == "" or target:sub(1, 1) == "/" then return false end
  if target:find("\\", 1, true) ~= nil then return false end
  if has_drive_or_unc(target) then return false end
  local depth = 0
  if rel_dir ~= "" then
    for _ in rel_dir:gmatch("[^/]+") do depth = depth + 1 end
  end
  for seg in (target .. "/"):gmatch("([^/]*)/") do
    if seg == "" or seg == "." then
      -- no change
    elseif seg == ".." then
      depth = depth - 1
      if depth < 0 then return false end
    else
      depth = depth + 1
    end
  end
  return true
end

--- Permission bits only, and never setuid, setgid or sticky -- those
--- all live above 0o777, so masking to it drops them along with any
--- file-type bits.
local function safe_mode(mode: integer): integer
  return mode & 0x1FF
end

local function dirname(path: string): string | nil
  return path:match("^(.*)/[^/]+$")
end

local function extract_file(dest_path: string, entry: Archive.Entry): boolean, string
  local parent = dirname(dest_path)
  if parent ~= nil then
    local made, trouble = Fs.mkdirs(parent)
    if not made then return false, trouble end
  end
  local body, otrouble = entry:open()
  if body == nil then return false, otrouble end
  local mode = safe_mode(entry.mode)
  if mode == 0 then mode = 0x1a4 end
  local w, ctrouble = Stream.create(dest_path, mode)
  if w == nil then return false, ctrouble end
  while true do
    local chunk, rtrouble = body:read()
    if chunk == nil then
      if rtrouble ~= "" then
        w:close()
        return false, rtrouble
      end
      break
    end
    local ok, wtrouble = w:write(chunk)
    if not ok then
      w:close()
      return false, wtrouble
    end
  end
  return w:close()
end

--- Unpacks `path` into `dest`. Refuses an absolute entry path, one
--- with a `..` component, and -- when `links` is "create" -- a
--- symlink whose target would land outside `dest`. Returns the
--- destination-relative paths actually written.
function Archive.extract(path: string, dest: string, opts?: Archive.ExtractOptions):
    {string} | nil, string
  opts = opts or {}
  local links_mode = opts.links or "skip"
  local reader, trouble = Archive.open(path)
  if reader == nil then return nil, trouble end

  local written: {string} = {}
  while true do
    local entry, etrouble = reader:next()
    if entry == nil then
      reader:close()
      if etrouble ~= "" then return nil, etrouble end
      return written, ""
    end
    if not safe_relative(entry.path) then
      reader:close()
      return nil, "archive: refusing an unsafe entry path: " .. entry.path
    end
    local rel = apply_strip(entry.path, opts.strip)
    if rel ~= nil and rel ~= "" and (opts.filter == nil or opts.filter(rel)) then
      local dest_path = (dest .. "/" .. rel):gsub("/+$", "")
      if entry.kind == "dir" then
        local made, mtrouble = Fs.mkdirs(dest_path)
        if not made then
          reader:close()
          return nil, mtrouble
        end
        written[#written + 1] = (rel:gsub("/+$", ""))
      elseif entry.kind == "file" then
        local ok, ftrouble = extract_file(dest_path, entry)
        if not ok then
          reader:close()
          return nil, ftrouble
        end
        written[#written + 1] = rel
      elseif entry.kind == "symlink" and links_mode == "create" then
        if not stays_inside(dirname(rel) or "", entry.linkpath) then
          reader:close()
          return nil, "archive: refusing a symlink escaping the destination: " .. entry.path
        end
        local parent = dirname(dest_path)
        if parent ~= nil then Fs.mkdirs(parent) end
        local ok, strouble = Fs.symlink(entry.linkpath, dest_path)
        if not ok then
          reader:close()
          return nil, strouble
        end
        written[#written + 1] = rel
      end
      -- a hardlink, an "other" entry, or a skipped symlink is neither
      -- written nor an error
    end
  end
end

return Archive
