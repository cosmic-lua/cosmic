--- One entry point over whatever archive format a file turns out to
--- be: detected from its first bytes, walked through a single Entry
--- shape shared by tar (plain or compressed) and zip, and extracted to
--- a destination directory with the usual path-escape refusals a
--- caller expects from something unpacking bytes it did not write.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Compress = require("cosmic.compress")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")

local record Archive
  --- Shared with `cosmic.tar`'s own Entry.kind; zip only ever produces
  --- "file", "dir" or "symlink".
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
    --- The next entry, nil and "" at the end, or nil and an error. For
    --- a compressed tar, the end also runs the decompressor to the end
    --- of its stream, so a truncated or corrupt one fails here rather
    --- than passing as a complete archive.
    next: function(ArchiveReader): Entry | nil, string
    close: function(ArchiveReader): boolean, string
  end

  record ExtractOptions
    --- A path prefix to drop from every path -- whole components only,
    --- with or without a trailing `/` -- or a number of leading path
    --- components to drop (tar's --strip-components). An entry the
    --- prefix does not match, or that runs out of components, is
    --- skipped.
    strip: string | integer
    --- Asked with a path already stripped; false skips the entry.
    filter: function(string): boolean
    --- "skip" (the default) or "create". Created symlinks are made
    --- last, after every other entry, and nothing is ever written
    --- through one, so no symlink -- this archive's or one already in
    --- `dest` -- can redirect a write outside `dest`.
    links: string
    --- What to do with an entry that cannot be extracted: a hard
    --- link, a device, a FIFO, a sparse file. "error" (the default)
    --- fails naming it; "skip" leaves it out.
    unsupported: string
    --- Whether to give each file, directory and symlink its archived
    --- modification time. On by default.
    mtimes: boolean
    --- Fails once the files written would total more than this many
    --- bytes. Unlimited by default.
    max_bytes: integer
    --- Fails once more than this many entries would be written.
    --- Unlimited by default.
    max_entries: integer
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

--- `source`, when given, is the decompressed stream `tr` reads: once
--- the tar end is reached, whatever follows it is read through to the
--- decompressor's own end, so its errors (a truncated stream, a bad
--- checksum) surface instead of vanishing with the unread tail.
local function wrap_tar(tr: Tar.TarReader, source: Stream.Reader | nil): Archive.ArchiveReader
  local finished = false
  local ar: Archive.ArchiveReader = {}
  ar.next = function(_self: Archive.ArchiveReader): Archive.Entry | nil, string
    local e, trouble = tr:next()
    if e == nil then
      if trouble == "" and source ~= nil and not finished then
        finished = true
        while true do
          local chunk, dtrouble = source:read()
          if chunk == nil then
            if dtrouble ~= "" then return nil, dtrouble end
            break
          end
        end
      end
      return nil, trouble
    end
    local out: Archive.Entry = {
      path = e.path, kind = e.kind, mode = e.mode, size = e.size,
      mtime = e.mtime, linkpath = e.linkpath,
    }
    out.open = function(_o: Archive.Entry): Stream.Reader | nil, string
      return e:open()
    end
    return out, ""
  end
  ar.close = function(_self: Archive.ArchiveReader): boolean, string
    return tr:close()
  end
  return ar
end

local zip_kinds: {Zip.Kind:Archive.Kind} = { file = "file", dir = "dir", symlink = "symlink" }

local function wrap_zip(zr: Zip.ZipReader): Archive.ArchiveReader
  local entries = zr:entries()
  local at = 0
  local ar: Archive.ArchiveReader = {}
  ar.next = function(_self: Archive.ArchiveReader): Archive.Entry | nil, string
    at = at + 1
    if at > #entries then return nil, "" end
    local e = entries[at]
    local out: Archive.Entry = {
      path = e.path, kind = zip_kinds[e.kind], mode = e.mode, size = e.size,
      mtime = e.mtime, linkpath = e.linkpath,
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
--- plain ustar tar, or a tar compressed with gzip, xz, or bzip2.
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
    return wrap_tar(Tar.reader(raw), nil), ""
  end
  if kind == "gzip" or kind == "xz" or kind == "bzip2" then
    local codec: Compress.Stream
    local ctrouble: string
    if kind == "gzip" then
      codec, ctrouble = Compress.inflater("gzip")
    elseif kind == "xz" then
      codec, ctrouble = Compress.xz_decoder()
    else
      codec, ctrouble = Compress.bz2_decoder()
    end
    if codec == nil then return nil, "archive: " .. path .. ": " .. ctrouble end
    local raw, otrouble = Stream.open(path)
    if raw == nil then return nil, otrouble end
    local transformed = Stream.transform(raw, codec)
    return wrap_tar(Tar.reader(transformed), transformed), ""
  end
  return nil, "archive: " .. path .. ": not a recognized archive format"
end

local function listed_open(_e: Archive.Entry): Stream.Reader | nil, string
  return nil, "archive: an entry from Archive.list cannot be opened; walk Archive.open instead"
end

--- Every entry of the archive at `path`. The reader is closed before
--- this returns, so the entries' `open` fails; walk `Archive.open` to
--- read bodies.
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
    -- Dropping the per-entry reader closure keeps a long listing small.
    entry.open = listed_open
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

--- False for an absolute path, a `\`-separated or drive/UNC path, one
--- holding a NUL byte (which every system call would silently cut the
--- path at), or one with a `..` component -- the archive path itself,
--- before `strip` is applied, since `strip` only removes a prefix or
--- leading components and cannot make an escaping path safe.
local function safe_relative(path: string): boolean
  if path == "" or path:sub(1, 1) == "/" then return false end
  if path:find("\0", 1, true) ~= nil then return false end
  if path:find("\\", 1, true) ~= nil then return false end
  if has_drive_or_unc(path) then return false end
  for segment in (path .. "/"):gmatch("([^/]*)/") do
    if segment == ".." then return false end
  end
  return true
end

--- `path` split into its components, without empty or `.` ones.
local function components(path: string): {string}
  local out: {string} = {}
  for segment in path:gmatch("[^/]+") do
    if segment ~= "." then out[#out + 1] = segment end
  end
  return out
end

local function apply_strip(path: string, strip: string | integer | nil): string | nil
  if strip == nil then return path end
  if strip is string then
    local prefix = strip:gsub("/+$", "")
    if prefix == "" then return path end
    if path:sub(1, #prefix) ~= prefix then return nil end
    local rest = path:sub(#prefix + 1)
    if rest ~= "" and rest:sub(1, 1) ~= "/" then return nil end
    return (rest:gsub("^/+", ""))
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

--- Whether a symlink in `rel_dir` with `target` stays inside the
--- extraction root, tracked as a lexical depth rather than by
--- resolving real paths, since the destination need not exist yet.
--- `extract` separately refuses a target that walks through another
--- symlink, which would make this lexical walk meaningless.
local function stays_inside(rel_dir: string, target: string): boolean
  if target == "" or target:sub(1, 1) == "/" then return false end
  if target:find("\0", 1, true) ~= nil then return false end
  if target:find("\\", 1, true) ~= nil then return false end
  if has_drive_or_unc(target) then return false end
  local depth = #components(rel_dir)
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

local function join(parts: {string}, n: integer): string
  return table.concat(parts, "/", 1, n)
end

local record PendingLink
  rel: string
  parts: {string}
  target: string
  mtime: integer
end

--- Unpacks `path` into `dest`. Refuses an absolute entry path, one
--- with a `..` component or a NUL byte, any entry whose path runs
--- through a symlink, and -- when `links` is "create" -- a symlink
--- whose target would land outside `dest`. Returns the
--- destination-relative paths actually written. A failure partway
--- leaves whatever was already written; a file that fails its own
--- checks (a CRC32, a size) is never put in place.
function Archive.extract(path: string, dest: string, opts?: Archive.ExtractOptions):
    {string} | nil, string
  opts = opts or {}
  local links_mode = opts.links or "skip"
  local skip_unsupported = opts.unsupported == "skip"
  local restore_mtimes = opts.mtimes ~= false
  local bytes_left = opts.max_bytes
  local entries_left = opts.max_entries
  local opened, trouble = Archive.open(path)
  if opened == nil then return nil, trouble end
  local reader: Archive.ArchiveReader = opened
  local dest_made, dest_trouble = Fs.mkdirs(dest)
  if not dest_made then
    reader:close()
    return nil, dest_trouble
  end

  local written: {string} = {}
  -- Directories under `dest` known to be real directories (not
  -- symlinks), by dest-relative path: checked with lstat, or made here.
  local real_dirs: {string:boolean} = {}
  -- Symlinks still to be made, by dest-relative path; a later entry
  -- at the same path replaces an earlier one.
  local pending: {string:PendingLink} = {}
  local pending_order: {PendingLink} = {}
  local dir_times: {{string, integer}} = {}

  local function bail(message: string): nil, string
    reader:close()
    return nil, message
  end

  --- Makes sure the first `n` components of `parts` name real
  --- directories under `dest`, creating missing ones, and refusing
  --- a symlink (made or to be made) anywhere along the way.
  local function ensure_dirs(parts: {string}, n: integer, entry_path: string): boolean, string
    for i = 1, n do
      local rel = join(parts, i)
      if pending[rel] ~= nil then
        return false, "archive: refusing to write through a symlink: " .. entry_path
      end
      if not real_dirs[rel] then
        local full = dest .. "/" .. rel
        local st, why, errno = sys.lstat(full)
        if st == nil then
          if errno ~= sys.ENOENT then return false, full .. ": " .. why end
          local made, mtrouble, merr = sys.mkdir(full, 0x1ed)
          if not made and merr ~= sys.EEXIST then return false, full .. ": " .. mtrouble end
          st = sys.lstat(full)
        end
        if st == nil or st.kind ~= "dir" then
          if st ~= nil and st.kind == "link" then
            return false, "archive: refusing to write through a symlink: " .. entry_path
          end
          return false, "archive: " .. full .. " is not a directory"
        end
        real_dirs[rel] = true
      end
    end
    return true, ""
  end

  local function extract_file(dest_path: string, entry: Archive.Entry): boolean, string
    local body, otrouble = entry:open()
    if body == nil then return false, otrouble end
    local mode = safe_mode(entry.mode)
    if mode == 0 then mode = 0x1a4 end
    local w, ctrouble = Stream.create(dest_path, mode)
    if w == nil then return false, ctrouble end
    local copied, rtrouble = Stream.copy(body, w, bytes_left)
    if copied == nil then
      w:abort()
      if bytes_left ~= nil and rtrouble:find("more than", 1, true) ~= nil then
        return false, "archive: more than " .. tostring(opts.max_bytes) ..
          " bytes to extract, at " .. entry.path
      end
      return false, rtrouble
    end
    if bytes_left ~= nil then bytes_left = bytes_left - copied end
    local ok, wtrouble = w:close()
    if not ok then return false, wtrouble end
    if restore_mtimes then Fs.set_mtime(dest_path, entry.mtime, entry.mtime) end
    return true, ""
  end

  --- Whether `target`, read from the directory `parts[1..n]`, walks
  --- through any symlink -- one this archive makes, or one already in
  --- `dest` -- before its last component. The lexical `stays_inside`
  --- check is only sound when it does not.
  local function target_crosses_link(parts: {string}, n: integer, target: string): boolean
    local at: {string} = {}
    for i = 1, n do at[i] = parts[i] end
    local segs = components(target)
    for k = 1, #segs - 1 do
      local seg = segs[k]
      if seg == ".." then
        at[#at] = nil
      else
        at[#at + 1] = seg
        local rel = table.concat(at, "/")
        if pending[rel] ~= nil then return true end
        local st = sys.lstat(dest .. "/" .. rel)
        if st ~= nil and st.kind == "link" then return true end
      end
    end
    return false
  end

  local function make_link(link: PendingLink): boolean, string
    local parts = link.parts
    -- Its own parents, like any other entry's, must be real
    -- directories -- `pending` still holds every link, made or not.
    local ok, why = ensure_dirs(parts, #parts - 1, link.rel)
    if not ok then return false, why end
    if target_crosses_link(parts, #parts - 1, link.target) then
      return false, "archive: refusing a symlink whose target runs through another symlink: " ..
        link.rel
    end
    local full = dest .. "/" .. link.rel
    local st = sys.lstat(full)
    if st ~= nil then
      if st.kind == "dir" then return false, "archive: " .. full .. " is a directory" end
      sys.unlink(full)
    end
    ok, why = Fs.symlink(link.target, full)
    if not ok then return false, why end
    if restore_mtimes then Fs.set_mtime(full, link.mtime, link.mtime) end
    return true, ""
  end

  while true do
    local got, etrouble = reader:next()
    if got == nil then
      if etrouble ~= "" then return bail(etrouble) end
      break
    end
    local entry: Archive.Entry = got
    if not safe_relative(entry.path) then
      return bail("archive: refusing an unsafe entry path: " .. entry.path)
    end
    local stripped = apply_strip(entry.path, opts.strip)
    local parts = stripped ~= nil and components(stripped) or {}
    local rel = join(parts, #parts)
    if #parts > 0 and (opts.filter == nil or opts.filter(stripped)) then
      local kind = entry.kind
      local wanted = kind == "dir" or kind == "file" or
        (kind == "symlink" and links_mode == "create")
      if not wanted and kind ~= "symlink" and not skip_unsupported then
        return bail("archive: cannot extract " .. entry.path .. ": unsupported entry kind '" ..
          kind .. "'")
      end
      if wanted then
        if entries_left ~= nil then
          if entries_left <= 0 then
            return bail("archive: more than " .. tostring(opts.max_entries) ..
              " entries to extract")
          end
          entries_left = entries_left - 1
        end
        local dest_path = dest .. "/" .. rel
        if kind == "symlink" then
          if not stays_inside(join(parts, #parts - 1), entry.linkpath) then
            return bail("archive: refusing a symlink escaping the destination: " .. entry.path)
          end
          local link: PendingLink = {
            rel = rel, parts = parts, target = entry.linkpath, mtime = entry.mtime,
          }
          pending[rel] = link
          pending_order[#pending_order + 1] = link
        else
          -- A later entry at a symlink's path replaces it.
          pending[rel] = nil
          if kind == "dir" then
            local ok, dtrouble = ensure_dirs(parts, #parts, entry.path)
            if not ok then return bail(dtrouble) end
            dir_times[#dir_times + 1] = { dest_path, entry.mtime }
          else
            local ok, dtrouble = ensure_dirs(parts, #parts - 1, entry.path)
            if not ok then return bail(dtrouble) end
            local fok, ftrouble = extract_file(dest_path, entry)
            if not fok then return bail(ftrouble) end
          end
          written[#written + 1] = rel
        end
      end
    end
  end

  for _, link in ipairs(pending_order) do
    if pending[link.rel] == link then
      local ok, ltrouble = make_link(link)
      if not ok then return bail(ltrouble) end
      written[#written + 1] = link.rel
    end
  end
  if restore_mtimes then
    -- Deepest last-listed first, so setting a directory's time is not
    -- undone by then touching something inside it.
    for i = #dir_times, 1, -1 do
      local d = dir_times[i]
      Fs.set_mtime(d[1], d[2], d[2])
    end
  end
  reader:close()
  return written, ""
end

return Archive
