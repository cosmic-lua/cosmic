--- ZIP archive reading and writing utilities.
--- Wraps cosmo.zip with a convenient Teal-typed interface for creating,
--- reading, and modifying ZIP archives. Use `reader`/`writer`/`appender`
--- to open by path, `from` for in-memory data, and `extract` to safely
--- unpack a reader to a directory (entry names from an archive are
--- attacker-controlled; never write them to disk without `extract`'s
--- zip-slip validation).
local zip = require("cosmo.zip")
local fs = require("cosmic.fs")

--- Options for opening a ZIP archive: compression level 0-9 (used when
--- writing/appending) and max_file_size limit. The generated
--- cosmo.zip.OpenOptions record.
local type OpenOptions = zip.OpenOptions

--- Options for adding a file to a ZIP archive: method ("store" or
--- "deflate"), mtime, and mode. The generated cosmo.zip.AddOptions record.
local type AddOptions = zip.AddOptions

--- File metadata within a ZIP archive: size, compressed_size, crc32,
--- mtime, method (0=stored, 8=deflated), and mode. The generated
--- cosmo.zip.Stat record.
local type Stat = zip.Stat

--- Directory entry returned by Reader:list(): name, size, and mode. The
--- generated cosmo.zip.Entry record.
local type Entry = zip.Entry

--- Reader for extracting files from a ZIP archive (the generated
--- cosmo.zip.Reader class): list(), stat(name), read(name), close().
--- Entry names come raw from the central directory: an archive built by
--- another tool can contain absolute or "../" names. Validate before
--- using a name as a filesystem path, or use extract().
local type Reader = zip.Reader

--- Writer for creating new ZIP archives (the generated cosmo.zip.Writer
--- class): add(name, content, options?), close().
local type Writer = zip.Writer

--- Appender for adding files to an existing ZIP archive (the generated
--- cosmo.zip.Appender class): add(name, content, options?), remove(name),
--- close().
local type Appender = zip.Appender

--- Options for extract().
local record ExtractOptions
  --- Refuse any entry whose declared uncompressed size exceeds this many
  --- bytes (checked before anything is read or written).
  max_file_size: integer
end

--- Open a ZIP archive for reading.
--- @param path string|integer File path or file descriptor
--- @param options OpenOptions? Size limits
--- @return Reader | nil The archive reader, or nil on error
--- @return string? Error message if opening failed
local function reader(path: string | integer, options?: OpenOptions): Reader | nil, string
  local handle: any
  local err: string
  if options then
    handle, err = zip.open(path, "r", options)
  else
    handle, err = zip.open(path, "r")
  end
  if not handle then
    return nil, err or "failed to open zip archive"
  end
  return handle as Reader -- cast: from any
end

--- Create a new ZIP archive for writing. Any existing file is truncated.
--- @param path string|integer File path or file descriptor
--- @param options OpenOptions? Compression level and size limits
--- @return Writer | nil The archive writer, or nil on error
--- @return string? Error message if opening failed
local function writer(path: string | integer, options?: OpenOptions): Writer | nil, string
  local handle: Writer
  local err: string
  if options then
    handle, err = zip.create(path, options)
  else
    handle, err = zip.create(path)
  end
  if not handle then
    return nil, err or "failed to create zip archive"
  end
  return handle
end

--- Open a ZIP archive for appending, creating it if it does not exist.
--- Unlike reader/writer, a file descriptor is not accepted; the archive
--- must be given as a path.
--- @param path string File path
--- @param options OpenOptions? Compression level and size limits
--- @return Appender | nil The archive appender, or nil on error
--- @return string? Error message if opening failed
local function appender(path: string, options?: OpenOptions): Appender | nil, string
  local handle: Appender
  local err: string
  if options then
    handle, err = zip.append(path, options)
  else
    handle, err = zip.append(path)
  end
  if not handle then
    return nil, err or "failed to open zip archive for appending"
  end
  return handle
end

--- Open a ZIP archive from in-memory data for reading.
--- @param data string The ZIP archive data
--- @param options OpenOptions? Size limits
--- @return Reader? The archive reader, or nil on error
--- @return string? Error message if opening failed
local function from(data: string, options?: OpenOptions): Reader | nil, string
  local handle: Reader
  local err: string
  if options then
    handle, err = zip.from(data, options)
  else
    handle, err = zip.from(data)
  end
  if not handle then
    return nil, err or "failed to open zip from data"
  end
  return handle
end

--- Report whether a zip entry name would escape the extraction root
--- (zip-slip). Rejects absolute paths — POSIX (`/x`), Windows/UNC
--- (`\x`, `\\server\share`), and drive-letter (`C:\x`, `C:/x`, `C:x`) —
--- and any `..` traversal component. Both `/` and `\` are treated as
--- separators, since cosmic executables also run on Windows where a
--- `..\evil` entry would otherwise slip past a POSIX-only guard.
local function unsafe_entry(name: string): boolean
  if name == "" then return true end
  -- Absolute roots escape the destination directory.
  if name:sub(1, 1) == "/" or name:sub(1, 1) == "\\" then return true end
  if name:match("^%a:") then return true end
  -- Normalize backslashes so ".." traversal is caught on either
  -- separator ("..\evil" like "../evil").
  local slashed = name:gsub("\\", "/")
  if slashed == ".." or slashed:match("^%.%./") or slashed:match("/%.%./")
  or slashed:match("/%.%.$") then
    return true
  end
  return false
end

--- Extract every entry of an open reader into destdir, refusing archives
--- that attempt zip-slip. All entry names (and sizes, when
--- opts.max_file_size is set) are validated before anything is written, so
--- a malicious archive fails without leaving partial output. File modes
--- are taken from the archive masked to 0777 (setuid/setgid/sticky bits
--- are stripped); entries without a mode default to 0644. Existing files
--- are overwritten. The reader is left open.
--- @param r Reader An open archive reader (from reader() or from())
--- @param destdir string Directory to extract into (created if needed)
--- @param opts ExtractOptions? Per-entry size limit
--- @return boolean true when every entry was written
--- @return string? Error message if validation or writing failed
local function extract(r: Reader, destdir: string, opts?: ExtractOptions): boolean, string
  local entries = r:list()

  -- Validate everything up front: a single bad entry rejects the whole
  -- archive before any bytes hit the filesystem. list() entries carry
  -- size and mode, so no per-entry stat is needed.
  for _, entry in ipairs(entries) do
    if unsafe_entry(entry.name) then
      return false, "unsafe path in archive: " .. entry.name
    end
    if opts and opts.max_file_size and entry.size > opts.max_file_size then
      return false, "entry exceeds max_file_size: " .. entry.name
    end
  end

  local made_dirs: {string: boolean} = {}
  local function ensure_dir(dir: string): boolean, string
    if made_dirs[dir] then return true end
    local ok, err = fs.makedirs(dir)
    if not ok then
      return false, "cannot create directory '" .. dir .. "': " .. (err or "unknown error")
    end
    made_dirs[dir] = true
    return true
  end

  local ok, err = ensure_dir(destdir)
  if not ok then return false, err end

  for _, entry in ipairs(entries) do
    local name = entry.name
    if name:sub(-1) == "/" then
      ok, err = ensure_dir(fs.join(destdir, name))
      if not ok then return false, err end
    else
      local content, read_err = r:read(name)
      if not content then
        return false, "cannot read '" .. name .. "' from archive: " .. (read_err or "unknown error")
      end
      local filepath = fs.join(destdir, name)
      ok, err = ensure_dir(fs.dirname(filepath))
      if not ok then return false, err end

      -- Sane-masked mode from the archive: permission bits only.
      local file_mode = tonumber("644", 8)
      local mode = entry.mode & tonumber("777", 8)
      if mode > 0 then
        file_mode = mode
      end

      local write_ok, write_err = fs.write(filepath, content, file_mode)
      if not write_ok then
        return false, "cannot write '" .. filepath .. "': " .. (write_err or "unknown error")
      end
      -- barf's mode only applies on create; force it for overwrites.
      fs.chmod(filepath, file_mode)
    end
  end
  return true
end

local record ZipModule
  --- Options for opening a ZIP archive.
  type OpenOptions = OpenOptions
  --- Options for adding a file to a ZIP archive.
  type AddOptions = AddOptions
  --- Options for extract().
  type ExtractOptions = ExtractOptions
  --- File metadata within a ZIP archive.
  type Stat = Stat
  --- Directory entry returned by Reader:list().
  type Entry = Entry
  --- Reader for extracting files from a ZIP archive.
  type Reader = Reader
  --- Writer for creating new ZIP archives.
  type Writer = Writer
  --- Appender for adding files to an existing ZIP archive.
  type Appender = Appender

  reader: function(path: string | integer, options?: OpenOptions): Reader | nil, string
  writer: function(path: string | integer, options?: OpenOptions): Writer | nil, string
  appender: function(path: string, options?: OpenOptions): Appender | nil, string
  from: function(data: string, options?: OpenOptions): Reader | nil, string
  extract: function(r: Reader, destdir: string, opts?: ExtractOptions): boolean, string
end

local M: ZipModule = {
  reader = reader,
  writer = writer,
  appender = appender,
  from = from,
  extract = extract,
}

return M
